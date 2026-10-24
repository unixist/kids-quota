import {HOST_NAME, STALE_AFTER_MS, PolicyState, makeBrowserState, makeBlockingRules, matchingRule, hostnameFromURL} from './core.js';

export function createController({api, platform, now = Date.now, sessionId = crypto.randomUUID(), timers = globalThis}) {
  const state = new PolicyState();
  let sequence = 0, nativePort = null, safariPending = false, interval = null, staleTimer = null, sweepSignature = null;
  let started = false, initialized = false, stopped = false, enforcementError = null, queue = Promise.resolve();
  let refreshRunning = null, refreshRequested = false;
  const blockedPage = api.runtime.getURL('blocked.html');

  function serial(task) {
    queue = queue.then(task).catch(() => { enforcementError = 'Website blocking needs attention. Open Kids Quota.'; });
    return queue;
  }
  async function reconcile() {
    const snapshot = state.snapshot(now(), enforcementError);
    const rules = makeBlockingRules(snapshot.rules, blockedPage);
    const signature = JSON.stringify(rules);
    // If storage has failed, preserve the browser's persisted DNR rules until a
    // valid live policy arrives; an unknown policy is not an empty policy.
    if (state.policy !== null && signature !== sweepSignature) {
      try {
        if (!api.declarativeNetRequest) throw new Error('Unsupported browser');
        const existing = await api.declarativeNetRequest.getDynamicRules();
        await api.declarativeNetRequest.updateDynamicRules({removeRuleIds:existing.map(rule => rule.id), addRules:rules});
        sweepSignature = signature;
        enforcementError = null;
      } catch {
        enforcementError = 'Website blocking permission is missing or unavailable. Open Kids Quota.';
      }
    }
    // Existing pages and cached playback must be replaced, not just future requests.
    const tabs = await api.tabs.query({});
    await Promise.all(tabs.map(async tab => {
      const host = hostnameFromURL(tab.url);
      const rule = host && matchingRule(host, snapshot.rules);
      if (rule?.blocked && Number.isInteger(tab.id)) {
        try { await api.tabs.update(tab.id,{url:`${blockedPage}?service=${encodeURIComponent(rule.serviceId)}`}); }
        catch { /* The user may have closed the tab while we enumerated it. */ }
      }
    }));
    const action = api.action || api.browserAction;
    if (action?.setBadgeText) {
      await action.setBadgeText({text:enforcementError ? '!' : snapshot.configured && !snapshot.connected ? '…' : ''}).catch(()=>{});
    }
  }
  function acceptPolicy(message) {
    return serial(async () => {
      if (!state.accept(message, now())) return false;
      if (staleTimer !== null) timers.clearTimeout(staleTimer);
      // A stalled Safari request must not postpone the fail-closed deadline.
      staleTimer = timers.setTimeout(()=>{void serial(reconcile);},STALE_AFTER_MS);
      let persistenceFailed = false;
      try { await api.storage.local.set({lastPolicy:{policy:state.policy}}); }
      catch { persistenceFailed = true; }
      await reconcile();
      if (persistenceFailed) enforcementError = 'Website policy could not be saved. Open Kids Quota.';
      return true;
    });
  }
  function connectChrome() {
    if (nativePort || stopped) return;
    try {
      const port = api.runtime.connectNative(HOST_NAME);
      nativePort = port;
      port.onMessage.addListener(message => { void acceptPolicy(message); });
      port.onDisconnect.addListener(() => {
        // Read lastError to avoid noisy rejected-port messages; it contains no policy.
        void api.runtime.lastError;
        if (nativePort === port) nativePort = null;
        void serial(reconcile);
      });
    } catch { nativePort = null; }
  }
  async function sendState(payload) {
    if (platform === 'safari') {
      if (safariPending) return;
      safariPending = true;
      let timeout;
      try {
        // Safari native messages are request/reply to the containing app extension.
        const reply = await Promise.race([
          api.runtime.sendNativeMessage(HOST_NAME, payload),
          new Promise((_,reject)=>{timeout=timers.setTimeout(()=>reject(new Error('Native timeout')),8000);})
        ]);
        await acceptPolicy(reply);
      } catch { await serial(reconcile); }
      finally { timers.clearTimeout(timeout); safariPending = false; }
    } else {
      connectChrome();
      try { nativePort?.postMessage(payload); }
      catch { nativePort = null; }
    }
  }
  async function readState() {
    let window = null, tab = null;
    try {
      window = await api.windows.getLastFocused({populate:false});
      if (window?.focused) [tab] = await api.tabs.query({active:true, windowId:window.id});
    } catch { /* No accessible browser window. Report inactivity. */ }
    return makeBrowserState({browser:platform, sessionId, sequence:++sequence, window, tab});
  }
  function refresh() {
    if (stopped) return Promise.resolve();
    refreshRequested = true;
    if (!initialized) return Promise.resolve();
    if (!refreshRunning) {
      refreshRunning = (async () => {
        // Coalesce event bursts; always re-read the latest tab after in-flight work.
        while (refreshRequested && !stopped) {
          refreshRequested = false;
          const payload = await readState();
          await sendState(payload);
          await serial(reconcile);
        }
      })().catch(()=>{}).finally(()=>{
        refreshRunning=null;
        if (refreshRequested && !stopped) void refresh();
      });
    }
    return refreshRunning;
  }
  async function handleMessage(message, sender) {
    if (sender?.id !== api.runtime.id) return {error:'Unauthorized extension message'};
    if (message?.type === 'wake') { void refresh(); return {ok:true}; }
    if (message?.type === 'status') {
      void refresh();
      return state.snapshot(now(),enforcementError);
    }
    if (message?.type === 'blockedInfo') {
      void refresh();
      const snapshot = state.snapshot(now(),enforcementError);
      const rule = snapshot.rules.find(item=>item.serviceId===message.serviceId);
      return {connected:snapshot.connected, rule:rule || null};
    }
    return {error:'Unknown extension message'};
  }
  async function start() {
    if (started) return;
    started = true;
    // Register synchronously: Chrome can dispatch the event that woke this worker
    // before an asynchronous storage read finishes.
    const onChange = () => { void refresh(); };
    api.tabs.onActivated.addListener(onChange);
    api.tabs.onUpdated.addListener((_id,change)=>{if(change.url || change.status === 'complete') onChange();});
    api.tabs.onRemoved.addListener(onChange);
    api.windows.onFocusChanged.addListener(onChange);
    api.runtime.onMessage.addListener((message,sender,reply)=>{handleMessage(message,sender).then(reply,()=>reply({error:'Unavailable'}));return true;});
    api.alarms.onAlarm.addListener(alarm=>{if(alarm.name==='quota-refresh') onChange();});
    api.runtime.onStartup?.addListener(onChange);
    api.runtime.onInstalled?.addListener(onChange);
    try {
      const cached = await api.storage.local.get('lastPolicy');
      state.restore(cached.lastPolicy);
    } catch { enforcementError = 'Saved website policy is unavailable. Open Kids Quota.'; }
    initialized = true;
    await api.alarms.create('quota-refresh',{periodInMinutes:1});
    // Native Chrome ports keep the worker alive. Content lifecycle messages and
    // alarms recover from suspension; the service never trusts this timer as a clock.
    interval = timers.setInterval(onChange,5000);
    await serial(reconcile);
    await refresh();
  }
  function stop() {
    stopped = true;
    if (interval !== null) timers.clearInterval(interval);
    if (staleTimer !== null) timers.clearTimeout(staleTimer);
    nativePort?.disconnect();
  }
  return {start,stop,refresh,acceptPolicy,reconcile:()=>serial(reconcile),snapshot:()=>state.snapshot(now(),enforcementError),handleMessage};
}
