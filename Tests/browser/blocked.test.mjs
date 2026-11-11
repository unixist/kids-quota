import test from 'node:test';
import assert from 'node:assert/strict';
import {blockedPresentation,createBlockedPage} from '../../extensions/shared/blocked.js';

const dateOptions={locale:'en-US',timeZone:'America/Chicago'};
function response(overrides={}) {
  return {connected:true,resetTimeZone:'America/Chicago',rule:{
    serviceId:'chess',name:'Chess.com',domains:[{hostname:'chess.com',includeSubdomains:true}],
    remainingSeconds:21600,resetAt:'2026-11-16T06:00:00Z',blocked:true,reason:'collector_unavailable'
  },...overrides};
}
function harness() {
  class Element {
    constructor(){this.textContent='';this.disabled=false;this.listeners={};}
    addEventListener(name,listener){this.listeners[name]=listener;}
    removeEventListener(name,listener){if(this.listeners[name]===listener) delete this.listeners[name];}
  }
  const elements=Object.fromEntries(['title','balance','message','reset','notice','retry','refresh'].map(id=>[id,new Element()]));
  const document={getElementById:id=>elements[id]}, messages=[], navigations=[];
  let reply=response(),interval,deadline,intervalMS,cleared=false;
  const api={runtime:{sendMessage:async message=>{
    messages.push(message);
    if(reply instanceof Error) throw reply;
    return typeof reply==='function'?reply():reply;
  }}};
  const timers={setInterval:(fn,ms)=>{interval=fn;intervalMS=ms;return 1;},clearInterval:()=>{cleared=true;},
    setTimeout:fn=>{deadline=fn;return 2;},clearTimeout:()=>{}};
  const listeners={},lifecycle={addEventListener:(name,fn)=>{listeners[name]=fn;}};
  const location={href:'chrome-extension://test/blocked.html?service=chess',assign:url=>navigations.push(url)};
  const page=createBlockedPage({document,api,location,timers,lifecycle,dateOptions});
  return {page,elements,messages,navigations,listeners,setResponse:value=>{reply=value;},interval:()=>interval(),
    deadline:()=>deadline(),intervalMS:()=>intervalMS,cleared:()=>cleared};
}

test('a fresh full six-hour balance is paused for monitoring rather than described as exhausted',()=>{
  for(const reason of ['collector_unavailable','exhausted',undefined]) {
    const data=response();data.rule.reason=reason;
    const model=blockedPresentation(data,dateOptions);
    assert.equal(model.title,'Chess.com is paused');
    assert.equal(model.balance,'6 h remaining');
    assert.match(model.message,/Mac activity monitor is not connected/);
    assert.match(model.notice,/sign out of this Mac account and sign back in/);
    assert.match(model.reset,/Monday, Nov 16/);
    assert.match(model.reset,/12:00 AM CST/);
    assert.equal(model.returnURL,null);
  }
});

test('only a current zero balance says weekly limit reached; a restored positive balance enables return',()=>{
  const data=response();data.rule.remainingSeconds=0;data.rule.reason='exhausted';
  assert.equal(blockedPresentation(data,dateOptions).title,'Chess.com: weekly limit reached');
  assert.equal(blockedPresentation(data,dateOptions).balance,'0 min remaining');
  data.rule.remainingSeconds=1;data.rule.blocked=false;data.rule.reason='available';
  const available=blockedPresentation(data,dateOptions);
  assert.equal(available.title,'Your allowance is available');
  assert.equal(available.balance,'Less than 1 min remaining');
  assert.equal(available.returnURL,'https://chess.com/');
});

test('stale cached exhaustion and stale positive balances never claim current exhaustion or available time',()=>{
  for(const remainingSeconds of [0,21600]) {
    const data=response({connected:false});data.rule.remainingSeconds=remainingSeconds;
    const model=blockedPresentation(data,dateOptions);
    assert.equal(model.title,'Waiting for Kids Quota');
    assert.equal(model.balance,'');
    assert.equal(model.returnURL,null);
    assert.equal(model.reset,'');
  }
  assert.equal(blockedPresentation(response({rule:null})).title,'Website status unavailable');
});

test('the block page uses the authoritative Chicago timezone rather than the browser timezone',()=>{
  const model=blockedPresentation(response(),{locale:'en-US',timeZone:'UTC'});
  assert.match(model.reset,/Monday, Nov 16/);
  assert.match(model.reset,/12:00 AM CST/);
});

test('an unsupported native timezone preserves balance and availability with an explicit UTC reset',()=>{
  const data=response({resetTimeZone:'GMT-0600'});
  data.rule.blocked=false;data.rule.reason='available';
  const model=blockedPresentation(data,dateOptions);
  assert.equal(model.title,'Your allowance is available');
  assert.equal(model.balance,'6 h remaining');
  assert.equal(model.returnURL,'https://chess.com/');
  assert.match(model.reset,/Monday, Nov 16/);
  assert.match(model.reset,/6:00 AM UTC/);
});

test('positive allowance does not offer a return link while the old browser block has not been removed',()=>{
  const data=response({enforcementError:'Website blocking permission is missing or unavailable.'});
  data.rule.blocked=false;data.rule.reason='available';
  const pending=blockedPresentation(data,dateOptions);
  assert.equal(pending.balance,'6 h remaining');
  assert.equal(pending.title,'Chess.com needs attention');
  assert.match(pending.message,/browser protection has not finished updating/);
  assert.equal(pending.returnURL,null);
  data.enforcementError=null;
  assert.equal(blockedPresentation(data,dateOptions).returnURL,'https://chess.com/');
});

test('the block page recovers after monitoring returns without resetting the remaining allowance',async()=>{
  const h=harness();
  await h.page.start();
  assert.equal(h.elements.title.textContent,'Chess.com is paused');
  assert.equal(h.elements.balance.textContent,'6 h remaining');
  assert.equal(h.elements.retry.disabled,true);
  assert.equal(h.intervalMS(),5000);
  const restored=response();restored.rule.blocked=false;restored.rule.reason='available';
  h.setResponse(restored);await h.interval();
  assert.equal(h.elements.title.textContent,'Your allowance is available');
  assert.equal(h.elements.balance.textContent,'6 h remaining');
  assert.equal(h.elements.retry.disabled,false);
  assert.equal(h.elements.notice.textContent,'');
  h.elements.retry.listeners.click();
  assert.deepEqual(h.navigations,['https://chess.com/']);
  assert.deepEqual(h.messages,[{type:'blockedInfo',serviceId:'chess'},{type:'blockedInfo',serviceId:'chess'}]);
  h.listeners.pagehide();
  assert.equal(h.cleared(),true);
  assert.equal(h.elements.retry.listeners.click,undefined);
});

test('a failed refresh clears obsolete balance and reset text and prevents navigation',async()=>{
  const h=harness();await h.page.start();
  h.setResponse(new Error('Disconnected'));await h.page.refresh();
  assert.equal(h.elements.title.textContent,'Kids Quota needs attention');
  assert.equal(h.elements.balance.textContent,'');
  assert.equal(h.elements.reset.textContent,'');
  assert.equal(h.elements.retry.disabled,true);
  h.elements.retry.listeners.click();assert.deepEqual(h.navigations,[]);
  h.setResponse(response());await h.page.refresh();
  assert.equal(h.elements.balance.textContent,'6 h remaining');
});

test('a delayed response cannot undo a later block-page recovery after its request timed out',async()=>{
  const h=harness();await h.page.start();
  let finish;
  h.setResponse(()=>new Promise(resolve=>{finish=resolve;}));
  const pending=h.page.refresh();
  await h.page.refresh();
  assert.equal(h.messages.length,2,'refresh requests coalesce while awaiting the controller');
  h.deadline();await pending;
  const restored=response();restored.rule.blocked=false;restored.rule.reason='available';
  h.setResponse(restored);await h.page.refresh();
  finish(response());await new Promise(resolve=>setImmediate(resolve));
  assert.equal(h.elements.title.textContent,'Your allowance is available');
  assert.equal(h.elements.retry.disabled,false);
  h.page.stop();
});

test('closing the block page stops updates from an in-flight response',async()=>{
  const h=harness();let finish;
  h.setResponse(()=>new Promise(resolve=>{finish=resolve;}));
  const pending=h.page.start();h.page.stop();finish(response());await pending;
  assert.equal(h.elements.title.textContent,'');
  assert.equal(h.elements.retry.disabled,true);
});
