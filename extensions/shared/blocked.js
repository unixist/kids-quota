// The service's balance and the reason access is paused are separate facts.
// This page only reads controller snapshots; it never alters quota or usage.
function remainingTime(seconds) {
  const minutes = Math.floor(Math.max(0, seconds) / 60);
  if (seconds > 0 && minutes === 0) return 'Less than 1 min';
  if (minutes >= 60) return `${Math.floor(minutes / 60)} h${minutes % 60 ? ` ${minutes % 60} min` : ''}`;
  return `${minutes} min`;
}

export function blockedPresentation(response, {locale, timeZone} = {}) {
  const rule = response?.rule;
  const unavailable = {title:'Website status unavailable', balance:'',
    message:'Open Kids Quota on this Mac to check setup. You can also enter a website address in your browser.',
    reset:'', notice:'Your balance will appear after Kids Quota reconnects.', returnURL:null};
  if (!rule) return unavailable;
  if (response.connected !== true || rule.reason === 'unavailable' ||
      !Number.isFinite(rule.remainingSeconds) || rule.remainingSeconds < 0) {
    return {...unavailable, title:'Waiting for Kids Quota',
      message:'This restricted website is paused while the quota service reconnects.',
      notice:'This does not mean your weekly time is used up.'};
  }
  const resetDate = new Date(rule.resetAt);
  const resetTimeZone = response.resetTimeZone || timeZone;
  const dateFormat = {
    weekday:'long', month:'short', day:'numeric', hour:'numeric', minute:'2-digit', timeZoneName:'short',
    ...(resetTimeZone ? {timeZone:resetTimeZone} : {})
  };
  let reset = '';
  if (Number.isFinite(resetDate.getTime())) {
    try { reset = `Resets ${new Intl.DateTimeFormat(locale, dateFormat).format(resetDate)}`; }
    catch {
      // Older browsers may not recognize a timezone already supported by macOS.
      reset = `Resets ${new Intl.DateTimeFormat(locale, {...dateFormat, timeZone:'UTC'}).format(resetDate)}`;
    }
  }
  const balance = `${remainingTime(rule.remainingSeconds)} remaining`;
  // Never infer exhaustion from a generic blocked flag or a legacy reason.
  if (rule.remainingSeconds === 0) {
    return {title:`${rule.name || 'This website'}: weekly limit reached`, balance, reset,
      message:'The website and its selected Mac app share one weekly allowance.',
      notice:'Website access resumes when your allowance is available.', returnURL:null};
  }
  if (rule.blocked || rule.reason === 'collector_unavailable') {
    return {title:`${rule.name || 'This website'} is paused`, balance, reset,
      message:'Your weekly allowance is available, but the Mac activity monitor is not connected.',
      notice:'Ask your parent to sign out of this Mac account and sign back in to restart the activity monitor. Then choose Refresh status.',
      returnURL:null};
  }
  if (response.enforcementError) {
    return {title:`${rule.name || 'This website'} needs attention`, balance, reset,
      message:'Your allowance is available, but browser protection has not finished updating.',
      notice:'Try Refresh status. If the website stays paused, ask your parent to open Kids Quota to check browser protection.',
      returnURL:null};
  }
  return {title:'Your allowance is available', balance, reset,
    message:'You can return to the website.', notice:'',
    returnURL:rule.domains?.[0]?.hostname ? `https://${rule.domains[0].hostname}/` : null};
}

export function createBlockedPage({document, api, location = globalThis.location,
  timers = globalThis, lifecycle = globalThis, dateOptions} = {}) {
  const serviceId = new URL(location.href).searchParams.get('service') || '';
  const byId = id => document.getElementById(id);
  let returnURL = null, pending = false, stopped = false, interval;
  function render(model) {
    for (const id of ['title','balance','message','reset','notice']) byId(id).textContent = model[id];
    returnURL = model.returnURL;
    byId('retry').disabled = !returnURL;
  }
  async function refresh() {
    if (pending || stopped) return;
    pending = true;
    returnURL = null;
    byId('retry').disabled = true;
    byId('refresh').disabled = true;
    let timeout;
    try {
      const response = await Promise.race([
        api.runtime.sendMessage({type:'blockedInfo',serviceId}),
        new Promise((_, reject) => {timeout = timers.setTimeout(() => reject(new Error('Status timed out')), 3000);})
      ]);
      if (!stopped) render(blockedPresentation(response, dateOptions));
    } catch {
      if (!stopped) render({title:'Kids Quota needs attention', balance:'', reset:'', returnURL:null,
        message:'Open the Kids Quota app to reconnect browser protection.',
        notice:'Your current allowance could not be checked. Try Refresh status.'});
    } finally {
      timers.clearTimeout(timeout);
      pending = false;
      if (!stopped) byId('refresh').disabled = false;
    }
  }
  const retry = () => {if (returnURL) location.assign(returnURL);};
  function stop() {
    stopped = true;
    returnURL = null;
    timers.clearInterval(interval);
    byId('refresh').removeEventListener('click',refresh);
    byId('retry').removeEventListener('click',retry);
  }
  function start() {
    byId('refresh').addEventListener('click',refresh);
    byId('retry').addEventListener('click',retry);
    lifecycle.addEventListener?.('pagehide',stop,{once:true});
    interval = timers.setInterval(refresh,5000);
    return refresh();
  }
  return {start,refresh,stop};
}

if (typeof document !== 'undefined' && (globalThis.browser || globalThis.chrome)) {
  createBlockedPage({document,api:globalThis.browser || globalThis.chrome}).start();
}
