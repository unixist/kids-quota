import test from 'node:test';
import assert from 'node:assert/strict';
import {createController} from '../../extensions/shared/controller.js';

const nextTurn=()=>new Promise(resolve=>setImmediate(resolve));
function event() { const listeners=[];return {listeners,addListener:fn=>listeners.push(fn),emit:(...args)=>listeners.forEach(fn=>fn(...args))}; }
function policy({blocked=false,sequence=1,revision=2,remainingSeconds=21600}={}) {
  return {type:'policy',revision,requestSequence:sequence,configured:true,coverage:'complete',rules:[
    {serviceId:'chess',name:'Chess.com',domains:[{hostname:'chess.com',includeSubdomains:true}],blocked,remainingSeconds,resetAt:'2026-10-26T05:00:00Z'}
  ]};
}
function harness(platform='chrome') {
  let time=1000, storage={}, dynamic=[];
  const changes=[], nativeMessages=[], timers={setInterval:()=>1,clearInterval:()=>{},setTimeout:()=>2,clearTimeout:()=>{}};
  const port={onMessage:event(),onDisconnect:event(),postMessage:message=>nativeMessages.push(message),disconnect:()=>{}};
  const tabs=[{id:1,windowId:4,active:true,url:'https://chess.com/game/1'},{id:2,windowId:4,active:false,url:'https://unrelated.example/'}];
  const api={
    runtime:{id:'test',getURL:path=>`chrome-extension://test/${path}`,connectNative:()=>port,onMessage:event(),onStartup:event(),onInstalled:event(),sendNativeMessage:async(_host,message)=>{nativeMessages.push(message);return policy({sequence:message.sequence});}},
    storage:{local:{get:async()=>storage,set:async value=>{storage=value;}}},
    declarativeNetRequest:{getDynamicRules:async()=>dynamic,updateDynamicRules:async change=>{changes.push(change);dynamic=change.addRules;}},
    tabs:{query:async filter=>tabs.filter(tab=>!filter.active || (tab.active && tab.windowId===filter.windowId)),update:async(id,change)=>{Object.assign(tabs.find(tab=>tab.id===id),change);},onActivated:event(),onUpdated:event(),onRemoved:event()},
    windows:{getLastFocused:async()=>({id:4,focused:true}),onFocusChanged:event()},
    alarms:{onAlarm:event(),create:async()=>{}},action:{setBadgeText:async()=>{}}
  };
  const controller=createController({api,platform,now:()=>time,sessionId:'session-test',timers});
  return {api,controller,port,tabs,changes,nativeMessages,timers,setTime:value=>{time=value;},setStorage:value=>{storage=value;},getDynamic:()=>dynamic};
}

test('exhaustion installs navigation rules and replaces already-loaded matching tabs',async()=>{
  const h=harness();
  assert.equal(await h.controller.acceptPolicy(policy({blocked:true})),true);
  assert.equal(h.getDynamic().length,1);
  assert.equal(h.tabs[0].url,'chrome-extension://test/blocked.html?service=chess');
  assert.equal(h.tabs[1].url,'https://unrelated.example/');
  const count=h.changes.length;
  await h.controller.acceptPolicy(policy({blocked:true,sequence:2,remainingSeconds:0}));
  assert.equal(h.changes.length,count,'balances do not churn unchanged DNR rules');
  assert.equal(await h.controller.acceptPolicy({type:'error',rules:[]}),false);
  assert.equal(h.getDynamic().length,1);
  await h.controller.acceptPolicy(policy({sequence:3,revision:3}));
  assert.equal(h.getDynamic().length,0,'native-authorized new allowance releases the restriction');
  assert.match(h.tabs[0].url,/blocked.html/,'reset never unexpectedly replaces a page the child is reading');
});

test('loss of valid native replies fails closed only for configured domains',async()=>{
  const h=harness();
  await h.controller.acceptPolicy(policy());
  h.setTime(15999);
  await h.controller.reconcile();assert.equal(h.getDynamic().length,0);
  h.setTime(16000);
  await h.controller.reconcile();assert.equal(h.getDynamic().length,1);
  assert.equal(h.tabs[1].url,'https://unrelated.example/');
  assert.equal(h.controller.snapshot().rules[0].reason,'unavailable');
  await h.controller.acceptPolicy(policy({sequence:2}));
  assert.equal(h.getDynamic().length,0);
});

test('startup registers wake listeners before awaiting storage and sends current state',async()=>{
  const h=harness();let release;
  h.api.storage.local.get=()=>new Promise(resolve=>{release=resolve;});
  const startup=h.controller.start();
  assert.equal(h.api.tabs.onActivated.listeners.length,1);
  assert.equal(h.api.runtime.onMessage.listeners.length,1);
  h.api.tabs.onActivated.emit({tabId:1});
  release({});await startup;
  assert.equal(h.nativeMessages[0].hostname,'chess.com');
  assert.equal(h.nativeMessages[0].sequence,1);
  h.controller.stop();
});

test('a cached allowing policy is blocked on restart until native revalidation',async()=>{
  const h=harness();h.setStorage({lastPolicy:{policy:policy()}});
  await h.controller.start();
  assert.equal(h.getDynamic().length,1);
  h.port.onMessage.emit(policy());await nextTurn();
  assert.equal(h.getDynamic().length,0);
  h.controller.stop();
});

test('Safari event bursts coalesce without losing the latest selection or sending concurrent native calls',async()=>{
  const h=harness('safari');let release;let active=0,maxActive=0;
  h.api.runtime.sendNativeMessage=async(_host,message)=>{
    h.nativeMessages.push(message);active++;maxActive=Math.max(maxActive,active);
    if(h.nativeMessages.length===1) await new Promise(resolve=>{release=resolve;});
    active--;return policy({sequence:message.sequence});
  };
  const startup=h.controller.start();await nextTurn();
  h.tabs[0].url='https://chatgpt.com/';
  for(let i=0;i<40;i++) h.api.tabs.onActivated.emit({tabId:1});
  release();await startup;
  assert.equal(h.nativeMessages.length,2);
  assert.equal(h.nativeMessages[1].hostname,'chatgpt.com');
  assert.equal(maxActive,1);
  h.controller.stop();
});

test('browser permission failures are visible while already-open restricted tabs still close',async()=>{
  const h=harness();h.api.declarativeNetRequest.updateDynamicRules=async()=>{throw new Error('denied');};
  await h.controller.acceptPolicy(policy({blocked:true}));
  assert.equal(h.controller.snapshot().coverage,'incomplete');
  assert.match(h.controller.snapshot().enforcementError,/permission/);
  assert.match(h.tabs[0].url,/blocked.html/);
});

test('failed policy persistence never prevents current enforcement',async()=>{
  const h=harness();h.api.storage.local.set=async()=>{throw new Error('quota');};
  await h.controller.acceptPolicy(policy({blocked:true}));
  assert.equal(h.getDynamic().length,1);
  assert.match(h.controller.snapshot().enforcementError,/saved/);
});

test('unknown policy never clears persisted browser rules and unauthenticated messages disclose no policy',async()=>{
  const h=harness();
  await h.controller.reconcile();assert.equal(h.changes.length,0);
  const result=await h.controller.handleMessage({type:'status'},{id:'another-extension'});
  assert.deepEqual(result,{error:'Unauthorized extension message'});
});

test('a Chrome native disconnect reconnects on the next wake and revalidates cached policy',async()=>{
  const h=harness();let connections=0;
  h.api.runtime.connectNative=()=>{connections++;return h.port;};
  await h.controller.start();
  h.port.onMessage.emit(policy());await nextTurn();
  assert.equal(connections,1);
  h.port.onDisconnect.emit();await h.controller.refresh();
  assert.equal(connections,2);
  assert.equal(h.nativeMessages.at(-1).sequence,2);
  h.controller.stop();
});

test('Safari native timeout allows later recovery without trusting a late reply',async()=>{
  const h=harness('safari');let timeout,lateReply;
  h.timers.setTimeout=callback=>{timeout=callback;return 2;};
  h.api.runtime.sendNativeMessage=()=>new Promise(resolve=>{lateReply=resolve;});
  const startup=h.controller.start();await nextTurn();
  timeout();await startup;
  assert.equal(h.controller.snapshot().connected,false);
  lateReply(policy());await nextTurn();
  assert.equal(h.controller.snapshot().connected,false);
  h.api.runtime.sendNativeMessage=async(_host,message)=>policy({sequence:message.sequence});
  await h.controller.refresh();
  assert.equal(h.controller.snapshot().connected,true);
  h.controller.stop();
});

test('repeated native errors cannot refresh stale allows or replace the last valid restrictions',async()=>{
  const h=harness();await h.controller.acceptPolicy(policy());
  for(const elapsed of [5000,10000,15000]) {
    h.setTime(1000+elapsed);
    assert.equal(await h.controller.acceptPolicy({type:'policy',revision:99,configured:false,rules:[],error:'Service unavailable'}),false);
    await h.controller.reconcile();
  }
  assert.equal(h.controller.snapshot().configured,true);
  assert.equal(h.controller.snapshot().connected,false);
  assert.equal(h.controller.snapshot().rules[0].serviceId,'chess');
  assert.equal(h.getDynamic().length,1);
});

test('the native silence deadline blocks independently of a pending native request',async()=>{
  const h=harness('safari');let deadline,release;
  h.timers.setTimeout=(callback,milliseconds)=>{if(milliseconds===15000) deadline=callback;return 2;};
  await h.controller.start();
  h.api.runtime.sendNativeMessage=()=>new Promise(resolve=>{release=resolve;});
  const pending=h.controller.refresh();await nextTurn();
  h.setTime(16000);deadline();await nextTurn();
  assert.equal(h.getDynamic().length,1);
  assert.equal(h.controller.snapshot().connected,false);
  release({type:'error',error:'Service unavailable'});await pending;
  h.controller.stop();
});
