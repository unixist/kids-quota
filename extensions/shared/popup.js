// This page only reads the authenticated browser controller's current snapshot.
// It never sends usage, settings, or reset requests.
export function remainingTime(seconds) {
  const minutes = Math.floor(Math.max(0, seconds) / 60);
  if (seconds > 0 && minutes === 0) return 'Less than 1 min';
  if (minutes >= 60) return `${Math.floor(minutes / 60)} h${minutes % 60 ? ` ${minutes % 60} min` : ''}`;
  return `${minutes} min`;
}

export function resetTime(value, {locale, timeZone} = {}) {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return null;
  return new Intl.DateTimeFormat(locale, {weekday:'short', month:'short', day:'numeric',
    hour:'numeric', minute:'2-digit', timeZoneName:'short', ...(timeZone ? {timeZone} : {})}).format(date);
}

export function popupPresentation(data, dateOptions) {
  if (!data || typeof data.configured !== 'boolean' || typeof data.connected !== 'boolean' || !Array.isArray(data.rules)) {
    throw new Error('Invalid status response');
  }
  const status = !data.configured ? 'Ask your parent to set up this account.'
    : !data.connected ? 'Time is unavailable. Waiting for Kids Quota to reconnect.'
    : data.enforcementError ? 'Your time is up to date. Browser protection needs your parent’s attention.'
    : data.coverage !== 'complete' ? 'Your time is up to date. Some protection needs your parent’s attention.'
    : 'Your remaining time this week';
  const rows = (data.configured ? data.rules : []).map(rule => {
    const current = data.connected && rule.reason !== 'unavailable' && Number.isFinite(rule.remainingSeconds) && rule.remainingSeconds >= 0;
    const exhausted = current && rule.remainingSeconds === 0;
    return {
      name:rule.name || rule.serviceId,
      domains:(rule.domains || []).map(domain => domain.hostname + (domain.includeSubdomains ? ' (and subdomains)' : '')).join(', '),
      balance:!current ? 'Time unavailable' : exhausted ? 'No time left' : `${remainingTime(rule.remainingSeconds)} left`,
      note:!current ? 'Reconnect to see your current balance.' : exhausted ? 'Your weekly allowance is used up.' : rule.blocked ? 'Website access is paused. Ask your parent for help.' : '',
      reset:current ? resetTime(rule.resetAt, dateOptions) : null,
      exhausted
    };
  });
  return {status, rows, empty:data.configured && data.connected && !rows.length ? 'No weekly limits are assigned to this account.' : ''};
}

export function createPopup({document, api, timers = globalThis, lifecycle = globalThis, dateOptions} = {}) {
  const status = document.getElementById('status');
  const list = document.getElementById('rules');
  const button = document.getElementById('refresh');
  let pending = false, stopped = false, interval;
  function element(tag, className, text) {
    const node = document.createElement(tag);
    node.className = className;
    node.textContent = text;
    return node;
  }
  function render(model) {
    status.textContent = model.status;
    list.replaceChildren();
    if (model.empty) list.append(element('p', 'secondary', model.empty));
    for (const row of model.rows) {
      const card = element('section', 'balance-card', '');
      card.append(element('h2', 'service-name', row.name));
      if (row.domains) card.append(element('p', 'service-domains secondary', row.domains));
      card.append(element('p', `balance-value${row.exhausted ? ' exhausted' : ''}`, row.balance));
      if (row.note) card.append(element('p', 'balance-note secondary', row.note));
      if (row.reset) card.append(element('p', 'reset-time secondary', `Resets ${row.reset}`));
      list.append(card);
    }
  }
  async function refresh() {
    if (pending || stopped) return;
    pending = true; button.disabled = true;
    let timeout;
    try {
      const reply = await Promise.race([
        api.runtime.sendMessage({type:'status'}),
        new Promise((_, reject) => { timeout = timers.setTimeout(() => reject(new Error('Status timed out')), 3000); })
      ]);
      if (!stopped) render(popupPresentation(reply, dateOptions));
    } catch {
      if (!stopped) render({status:'Time is unavailable. Try Refresh, or ask your parent for help.',rows:[]});
    } finally {
      timers.clearTimeout(timeout);
      pending = false;
      if (!stopped) button.disabled = false;
    }
  }
  function stop() {
    stopped = true;
    timers.clearInterval(interval);
    button.removeEventListener('click', refresh);
  }
  function start() {
    button.addEventListener('click', refresh);
    lifecycle.addEventListener?.('pagehide', stop, {once:true});
    interval = timers.setInterval(refresh, 5000);
    return refresh();
  }
  return {start, refresh, stop};
}

if (typeof document !== 'undefined' && (globalThis.browser || globalThis.chrome)) {
  createPopup({document, api:globalThis.browser || globalThis.chrome}).start();
}
