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
    {rules:[policy().rules[0],policy().rules[0]]}
  ]) assert.equal(normalizePolicy(policy(change)),null,JSON.stringify(change));
  const zero=policy();zero.rules[0].remainingSeconds=0;
  assert.equal(normalizePolicy(zero).rules[0].blocked,true);
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
