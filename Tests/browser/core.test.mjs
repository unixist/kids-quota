import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeHostname, hostnameFromURL, matchesDomain, normalizePolicy, PolicyState, makeBrowserState, makeBlockingRules} from '../../extensions/shared/core.js';

export function policy(overrides={}) {
  return {type:'policy', revision:2, requestSequence:1, configured:true, coverage:'complete', rules:[{
    serviceId:'chess', name:'Chess.com', domains:[{hostname:'chess.com',includeSubdomains:true}],
    blocked:false, remainingSeconds:21600, resetAt:'2026-10-26T05:00:00Z'
  }], ...overrides};
}

test('domain identity uses canonical hosts and label boundaries, never IPs or lookalike suffixes',()=>{
  assert.equal(normalizeHostname('HTTPS://PLAY.CHESS.COM.:443/game?private=1'),'play.chess.com');
  assert.equal(normalizeHostname('bücher.example'),'xn--bcher-kva.example');
  for (const input of ['https://127.0.0.1/','http://[::1]/','javascript:alert(1)','file:///tmp/site','localhost','bad_.com','']) {
    assert.equal(normalizeHostname(input),null,input);
  }
  const domain={hostname:'chess.com',includeSubdomains:true};
  assert.equal(matchesDomain('play.chess.com',domain),true);
  for(const host of ['evilchess.com','chess.com.evil.com','chess-com.example']) assert.equal(matchesDomain(host,domain),false);
  assert.equal(matchesDomain('play.chess.com',{...domain,includeSubdomains:false}),false);
  assert.equal(hostnameFromURL('chrome://extensions'),null);
  assert.equal(hostnameFromURL('chess.com'),null);
});

test('policy validation rejects partial or untrusted restrictions as a whole',()=>{
  assert.equal(normalizePolicy(policy()).rules[0].resetAt,'2026-10-26T05:00:00.000Z');
  for(const change of [
    {type:'error'}, {error:'temporary'}, {revision:-1}, {requestSequence:-1}, {configured:'true'},
    {rules:[{...policy().rules[0],remainingSeconds:NaN}]},
    {rules:[{...policy().rules[0],resetAt:'not a date'}]},
    {rules:[{...policy().rules[0],domains:[{hostname:'https://chess.com/',includeSubdomains:true}]}]},
    {rules:[{...policy().rules[0],domains:[{hostname:'chess.com',includeSubdomains:'true'}]}]},
    {rules:[policy().rules[0],policy().rules[0]]},
    {resetTimeZone:''}, {resetTimeZone:'   '}, {resetTimeZone:'a'.repeat(101)}, {resetTimeZone:42},
    {rules:[{...policy().rules[0],reason:'invented-reason'}]}
  ]) assert.equal(normalizePolicy(policy(change)),null,JSON.stringify(change));
  const zero=policy();zero.rules[0].remainingSeconds=0;
  assert.equal(normalizePolicy(zero).rules[0].blocked,true);
});

test('positive balances blocked by missing monitoring retain their balance and explicit reason',()=>{
  for (const reason of [undefined,'collector_unavailable','exhausted']) {
    const state=new PolicyState(), paused=policy();
    paused.rules[0].blocked=true;
    if (reason !== undefined) paused.rules[0].reason=reason;
    assert.equal(state.accept(paused,1000),true);
    assert.equal(state.snapshot(1000).connected,true);
    assert.equal(state.rules(1000)[0].remainingSeconds,21600);
    assert.equal(state.rules(1000)[0].reason,'collector_unavailable');
    assert.equal(state.rules(1000)[0].blocked,true);
    assert.equal(state.rules(16000)[0].reason,'unavailable','lost service contact is a separate state');
    assert.equal(state.accept(policy({requestSequence:2}),17000),true);
    assert.equal(state.rules(17000)[0].reason,'available');
    assert.equal(state.rules(17000)[0].blocked,false);
  }
  const exhausted=policy();exhausted.rules[0].remainingSeconds=0;
  assert.equal(normalizePolicy(exhausted).rules[0].reason,'exhausted');
  const inconsistent=policy();inconsistent.rules[0].reason='collector_unavailable';
  assert.equal(normalizePolicy(inconsistent).rules[0].blocked,true,'explicit monitor failure never grants access');
});

test('authoritative reset timezone survives fresh snapshots and cached restoration',()=>{
  const state=new PolicyState();
  assert.equal(state.accept(policy({resetTimeZone:'America/Chicago'}),1000),true);
  assert.equal(state.snapshot(1000).resetTimeZone,'America/Chicago');
  const restarted=new PolicyState();
  assert.equal(restarted.restore({policy:state.policy}),true);
  assert.equal(restarted.snapshot(1001).resetTimeZone,'America/Chicago');
  assert.equal(restarted.snapshot(1001).connected,false);
});

test('a timezone missing from the browser database never prevents authoritative balance recovery',()=>{
  for(const resetTimeZone of ['America/Coyhaique','GMT-0600']) {
    const state=new PolicyState(), exhausted=policy({resetTimeZone});
    exhausted.rules[0].remainingSeconds=0;exhausted.rules[0].blocked=true;
    assert.equal(state.accept(exhausted,1000),true);
    assert.equal(state.accept(policy({resetTimeZone,requestSequence:2}),2000),true);
    const current=state.snapshot(2000);
    assert.equal(current.connected,true);
    assert.equal(current.resetTimeZone,resetTimeZone);
    assert.equal(current.rules[0].remainingSeconds,21600);
    assert.equal(current.rules[0].reason,'available');
    assert.equal(current.rules[0].blocked,false);
  }
});

test('cached policies fail closed until live native contact; native time owns balances and reset',()=>{
  const state=new PolicyState();
  state.restore({policy:policy()});
  assert.equal(state.rules(100).at(0).blocked,true);
  assert.equal(state.accept(policy(),1000),true);
  assert.equal(state.rules(15999)[0].blocked,false);
  assert.equal(state.rules(16000)[0].blocked,true);
  assert.equal(state.rules(16000)[0].remainingSeconds,21600); // No invented browser clock deduction.
  assert.equal(state.rules(Date.parse('2026-11-01'))[0].blocked,true); // Clock alone cannot reset.
  assert.equal(state.rules(999)[0].blocked,true); // Backwards wall clock is not fresh.
  const reset=policy({requestSequence:2});reset.rules[0].resetAt='2026-11-02T06:00:00Z';
  assert.equal(state.accept(reset,17000),true);
  assert.equal(state.rules(17000)[0].blocked,false);
});

test('late replies, old policy revisions and old week snapshots cannot undo current decisions',()=>{
  const state=new PolicyState();
  const newest=policy({requestSequence:12});newest.rules[0].blocked=true;
  assert.equal(state.accept(newest,100),true);
  assert.equal(state.accept(policy({requestSequence:11}),200),false);
  assert.equal(state.accept(policy({revision:1,requestSequence:13}),200),false);
  const oldWeek=policy({requestSequence:13});oldWeek.rules[0].resetAt='2026-10-19T05:00:00Z';
  assert.equal(state.accept(oldWeek,200),false);
  assert.equal(state.accept({type:'error',rules:[]},200),false);
  assert.equal(state.rules(200)[0].blocked,true);
  assert.equal(state.lastContact,100);
  assert.equal(state.accept(policy({revision:3,requestSequence:14,configured:false,rules:[]}),300),true);
  assert.deepEqual(state.rules(300),[]); // An explicit valid parent configuration can remove a restriction.
});

test('a parent reset restores allowance in the same week and older policies cannot undo it',()=>{
  const state=new PolicyState();
  const exhausted=policy({revision:4,requestSequence:6});
  exhausted.rules[0].remainingSeconds=0;exhausted.rules[0].blocked=true;
  assert.equal(state.accept(exhausted,100),true);
  assert.equal(state.rules(100)[0].blocked,true);
  const reset=policy({revision:5,requestSequence:7});
  assert.equal(reset.rules[0].resetAt,exhausted.rules[0].resetAt);
  assert.equal(state.accept(reset,200),true);
  assert.equal(state.rules(200)[0].blocked,false);
  assert.equal(state.rules(200)[0].remainingSeconds,21600);
  assert.equal(state.accept({...exhausted,requestSequence:8},300),false);
  assert.equal(state.rules(300)[0].blocked,false);
});

test('browser state includes only the selected host and never an elapsed-time claim or full URL',()=>{
  const input={browser:'chrome',sessionId:'test',sequence:9,window:{id:4,focused:true},tab:{id:10,windowId:4,active:true,url:'https://chess.com/game/secret?q=private'}};
  assert.deepEqual(makeBrowserState(input),{type:'browserState',browser:'chrome',sessionId:'test',sequence:9,hostname:'chess.com',focused:true,tabId:10});
  for(const change of [
    {window:{id:4,focused:false}}, {tab:{...input.tab,windowId:5}},
    {tab:{...input.tab,active:false}}, {tab:{...input.tab,url:'chrome://extensions'}}, {tab:null}
  ]) {
    const state=makeBrowserState({...input,...change});
    assert.equal(state.focused,false);assert.equal(state.hostname,null);
  }
});

test('DNR navigations cover ports, canonical trailing dots and frames without suffix overblocking',()=>{
  const blocked={...policy().rules[0],blocked:true};
  const rules=makeBlockingRules([blocked],'chrome-extension://test/blocked.html');
  assert.equal(rules.length,1);
  const expression=new RegExp(rules[0].condition.regexFilter,'i');
  for(const url of ['https://chess.com/','https://PLAY.chess.com:443/','https://chess.com./','http://user:password@chess.com/?x=1','https://chess.com?x=1']) assert.equal(expression.test(url),true,url);
  for(const url of ['https://chess.com.evil.com/','https://evilchess.com/','https://example.com/chess.com/','https://chess.com@evil.com/']) assert.equal(expression.test(url),false,url);
  assert.deepEqual(rules[0].condition.resourceTypes,['main_frame','sub_frame']);
  assert.equal(rules[0].action.redirect.url,'chrome-extension://test/blocked.html?service=chess');
  const exact=makeBlockingRules([{...blocked,domains:[{hostname:'chess.com',includeSubdomains:false}]}],'extension://block');
  assert.equal(new RegExp(exact[0].condition.regexFilter).test('https://play.chess.com/'),false);
  assert.deepEqual(makeBlockingRules(policy().rules,'extension://block'),[]);
});
