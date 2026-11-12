import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { loadConnections, runSmoke } from '../../scripts/cloud-smoke.mjs';

function files(t) {
  const base = mkdtempSync(resolve(tmpdir(), 'kq-smoke-test-')); chmodSync(base, 0o700);
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const folder = resolve(base, 'private'); mkdirSync(folder, { mode: 0o700 });
  const parent = { schemaVersion: 1, endpoint: 'https://test-relay.run.app', familyName: 'Test', readToken: 'r'.repeat(43) };
  const mac = { schemaVersion: 1, endpoint: parent.endpoint, deviceId: 'mac-1', deviceName: 'Test Mac', writeToken: 'w'.repeat(43) };
  const parentFile = resolve(folder, 'parent.json'), macFile = resolve(folder, 'mac.json');
  const save = () => { writeFileSync(parentFile, JSON.stringify(parent), { mode: 0o600 }); writeFileSync(macFile, JSON.stringify(mac), { mode: 0o600 }); };
  save(); return { parent, mac, parentFile, macFile, save };
}
test('smoke verifies authentication with rejected writes and never outputs credentials', async t => {
  const f = files(t), connections = loadConnections(f.parentFile, f.macFile), output = [], calls = [];
  const codes = [200, 401, 200, 403, 403, 403];
  const result = await runSmoke(connections, { report: line => output.push(line), fetcher: async (url, options) => {
    const index = calls.length; calls.push({ url, options });
    assert.equal(options.redirect, 'error'); assert.ok(options.signal);
    return new Response(index === 2 ? JSON.stringify({ schemaVersion: 1, devices: [{ deviceId: 'mac-1', snapshot: null }] }) : '{}', { status: codes[index] });
  } });
  assert.deepEqual(result, { reporting: 0, devices: 1 });
  assert.equal(calls.filter(c => c.options.method === 'PUT').length, 2);
  assert.ok(calls.filter(c => c.options.method === 'PUT').every(c => c.options.body === '{}'));
  assert.ok(!output.join('\n').includes(f.parent.readToken)); assert.ok(!output.join('\n').includes(f.mac.writeToken));
  assert.ok(calls.every(c => !c.url.includes(f.parent.readToken) && !c.url.includes(f.mac.writeToken)));
});
test('smoke rejects placeholder/mismatched endpoints and unsafe files before requests', t => {
  const f = files(t);
  f.parent.endpoint = 'https://SET-AFTER-DEPLOYMENT.invalid'; f.save();
  assert.throws(() => loadConnections(f.parentFile, f.macFile));
  f.parent.endpoint = 'https://another-relay.run.app'; f.save();
  assert.throws(() => loadConnections(f.parentFile, f.macFile));
  for (const endpoint of ['https://test-relay.run.app:0', 'https://test-relay.run.app:', ' https://test-relay.run.app']) {
    f.parent.endpoint = endpoint; f.mac.endpoint = endpoint; f.save();
    assert.throws(() => loadConnections(f.parentFile, f.macFile));
  }
  f.mac.endpoint = 'https://test-relay.run.app';
  f.parent.endpoint = f.mac.endpoint; f.save(); chmodSync(f.parentFile, 0o644);
  assert.throws(() => loadConnections(f.parentFile, f.macFile));
});
test('smoke sanitizes malformed private JSON and network errors containing credentials', async t => {
  const f = files(t), connections = loadConnections(f.parentFile, f.macFile);
  writeFileSync(f.parentFile, f.parent.readToken);
  assert.throws(() => loadConnections(f.parentFile, f.macFile), error => !error.message.includes(f.parent.readToken));
  await assert.rejects(runSmoke(connections, { report: () => {}, fetcher: async () => { throw new Error(`fetch ${f.parent.readToken}`); } }), error => !error.message.includes(f.parent.readToken));
});
