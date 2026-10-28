import test from 'node:test';
import assert from 'node:assert/strict';
import {createPopup, popupPresentation, remainingTime, resetTime} from '../../extensions/shared/popup.js';

const dateOptions = {locale:'en-US', timeZone:'America/Chicago'};
function snapshot(overrides = {}) {
  return {configured:true, connected:true, coverage:'complete', rules:[{
    serviceId:'chess', name:'Chess.com', domains:[{hostname:'chess.com', includeSubdomains:true}],
    remainingSeconds:7260, resetAt:'2026-10-26T05:00:00Z', blocked:false, reason:'available'
  }], ...overrides};
}
function harness() {
  class Element {
    constructor(tag = '') {this.tagName = tag; this.children = []; this.textContent = ''; this.listeners = {};}
    append(...nodes) { this.children.push(...nodes); }
    replaceChildren(...nodes) { this.children = nodes; }
    addEventListener(name, listener) {this.listeners[name] = listener;}
    removeEventListener(name, listener) {if (this.listeners[name] === listener) delete this.listeners[name];}
    text() {return [this.textContent, ...this.children.map(child => child.text())].join(' ');}
  }
  const elements = {status:new Element(), rules:new Element(), refresh:new Element()};
  const document = {getElementById:id => elements[id], createElement:tag => new Element(tag)};
  let response = snapshot(), interval, intervalMS, deadline, cleared = false;
  const messages = [];
  const api = {runtime:{sendMessage:async message => {
    messages.push(message);
    if (response instanceof Error) throw response;
    return typeof response === 'function' ? response() : response;
  }}};
  const timers = {
    setInterval:(callback, milliseconds) => {interval = callback; intervalMS = milliseconds; return 1;},
    clearInterval:() => {cleared = true;},
    setTimeout:callback => {deadline = callback; return 2;}, clearTimeout:() => {}
  };
  const listeners = {};
  const lifecycle = {addEventListener:(name, listener) => {listeners[name] = listener;}};
  const popup = createPopup({document, api, timers, lifecycle, dateOptions});
  return {popup, elements, messages, listeners, setResponse:value => {response = value;},
    interval:() => interval(), intervalMS:() => intervalMS, deadline:() => deadline(), cleared:() => cleared};
}

test('child balance formatting does not round up the last minute or hour', () => {
  assert.equal(remainingTime(0), '0 min');
  assert.equal(remainingTime(1), 'Less than 1 min');
  assert.equal(remainingTime(59), 'Less than 1 min');
  assert.equal(remainingTime(60), '1 min');
  assert.equal(remainingTime(3599), '59 min');
  assert.equal(remainingTime(3600), '1 h');
  assert.equal(remainingTime(7260), '2 h 1 min');
});

test('each child service shows its domains and next reset in the viewer timezone', () => {
  const data = snapshot();
  data.rules[0].domains.push({hostname:'chesskid.com', includeSubdomains:false});
  const model = popupPresentation(data, dateOptions);
  assert.equal(model.rows[0].name, 'Chess.com');
  assert.equal(model.rows[0].balance, '2 h 1 min left');
  assert.equal(model.rows[0].domains, 'chess.com (and subdomains), chesskid.com');
  assert.match(model.rows[0].reset, /Mon, Oct 26/);
  assert.match(model.rows[0].reset, /12:00 AM CDT/);
  assert.equal(resetTime('invalid', dateOptions), null);
});

test('a paused website with remaining allowance is never described as exhausted', () => {
  const data = snapshot();
  data.rules[0].blocked = true;
  data.rules[0].reason = 'exhausted'; // Legacy controller reason also covers missing collector.
  const row = popupPresentation(data, dateOptions).rows[0];
  assert.equal(row.balance, '2 h 1 min left');
  assert.equal(row.exhausted, false);
  assert.match(row.note, /Website access is paused/);
  data.rules[0].remainingSeconds = 0;
  const exhausted = popupPresentation(data, dateOptions).rows[0];
  assert.equal(exhausted.balance, 'No time left');
  assert.equal(exhausted.exhausted, true);
});

test('disconnected or stale snapshots never present cached numbers as current balances', () => {
  for (const data of [snapshot({connected:false}), snapshot()]) {
    if (data.connected) data.rules[0].reason = 'unavailable';
    const row = popupPresentation(data, dateOptions).rows[0];
    assert.equal(row.balance, 'Time unavailable');
    assert.equal(row.reset, null);
    assert.equal(row.exhausted, false);
  }
});

test('unconfigured accounts disclose no cached rows and empty assignments explain the state', () => {
  const unconfigured = popupPresentation(snapshot({configured:false}), dateOptions);
  assert.deepEqual(unconfigured.rows, []);
  assert.match(unconfigured.status, /Ask your parent/);
  assert.match(popupPresentation(snapshot({rules:[]}), dateOptions).empty, /No weekly limits/);
  assert.throws(() => popupPresentation({error:'Unauthorized extension message'}));
});

test('popup renders text safely and auto-refreshes read-only balances every five seconds', async () => {
  const h = harness(), data = snapshot();
  data.rules[0].name = '<script>not markup</script>';
  h.setResponse(data);
  await h.popup.start();
  assert.equal(h.intervalMS(), 5000);
  assert.match(h.elements.rules.text(), /<script>not markup<\/script>/);
  assert.match(h.elements.rules.text(), /2 h 1 min left/);
  assert.equal(h.elements.rules.children[0].children[0].tagName, 'h2');
  data.rules[0].remainingSeconds = 1800;
  await h.interval();
  assert.match(h.elements.rules.text(), /30 min left/);
  assert.deepEqual(h.messages, [{type:'status'}, {type:'status'}]);
  h.listeners.pagehide();
  assert.equal(h.cleared(), true);
  assert.equal(h.elements.refresh.listeners.click, undefined);
});

test('a failed refresh clears previous balances and recovers on the next refresh', async () => {
  const h = harness();
  await h.popup.start();
  h.setResponse(new Error('Disconnected'));
  await h.popup.refresh();
  assert.equal(h.elements.rules.children.length, 0);
  assert.match(h.elements.status.textContent, /Time is unavailable/);
  assert.equal(h.elements.refresh.disabled, false);
  h.setResponse(snapshot());
  await h.popup.refresh();
  assert.match(h.elements.rules.text(), /2 h 1 min left/);
});

test('a silent request times out without stale balances or accepting a later response', async () => {
  const h = harness();
  await h.popup.start();
  let complete;
  h.setResponse(() => new Promise(resolve => {complete = resolve;}));
  const pending = h.popup.refresh();
  await h.popup.refresh();
  assert.equal(h.messages.length, 2, 'overlapping refreshes coalesce');
  h.deadline();
  await pending;
  assert.equal(h.elements.rules.children.length, 0);
  complete(snapshot());
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.elements.rules.children.length, 0, 'timed-out reply cannot restore a stale balance');
});

test('closing the popup prevents an in-flight response from changing its view', async () => {
  const h = harness();
  let complete;
  h.setResponse(() => new Promise(resolve => {complete = resolve;}));
  const pending = h.popup.start();
  h.popup.stop();
  complete(snapshot());
  await pending;
  assert.equal(h.elements.rules.children.length, 0);
});
