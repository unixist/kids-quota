import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tokenDigest } from '../src/validation.mjs';

const script = resolve(dirname(fileURLToPath(import.meta.url)), '../../scripts/cloud-provision.mjs');
test('provisioning creates distinct owner-only credentials and prints no tokens', t => {
  const temporary = mkdtempSync(resolve(tmpdir(), 'kq-provision-test-'));
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  const output = resolve(temporary, 'private');
  const stdout = execFileSync(process.execPath, [script, '--out', output, '--family', 'Test family'], { encoding: 'utf8' });
  assert.equal(statSync(output).mode & 0o077, 0);
  const config = JSON.parse(readFileSync(resolve(output, 'auth-config.json')));
  assert.equal(config.devices.length, 2); assert.equal(config.readers.length, 2);
  const tokens = [];
  for (const name of readdirSync(output)) assert.equal(statSync(resolve(output, name)).mode & 0o077, 0);
  for (const item of config.devices) {
    const document = JSON.parse(readFileSync(resolve(output, `${item.deviceId}.json`)));
    tokens.push(document.writeToken); assert.equal(document.writeToken.length, 43);
    assert.equal(tokenDigest(document.writeToken), item.tokenSha256);
  }
  for (const item of config.readers) {
    const document = JSON.parse(readFileSync(resolve(output, `${item.id}.json`)));
    tokens.push(document.readToken); assert.equal(tokenDigest(document.readToken), item.tokenSha256);
  }
  assert.equal(new Set(tokens).size, 4);
  assert.ok(tokens.every(token => !stdout.includes(token) && !JSON.stringify(config).includes(token)));
  assert.notEqual(spawnSync(process.execPath, [script, '--out', output]).status, 0);
  execFileSync(process.execPath, [script, '--out', output, '--set-endpoint', 'https://relay.example/']);
  const parent = JSON.parse(readFileSync(resolve(output, 'parent-1.json')));
  assert.equal(parent.endpoint, 'https://relay.example'); assert.equal(parent.readToken, tokens[2]);
  const after = JSON.parse(readFileSync(resolve(output, 'auth-config.json')));
  assert.deepEqual(after, config);
});
test('provisioning rejects an in-repository credential directory and non-HTTPS endpoints', () => {
  const root = resolve(dirname(script), '..');
  assert.notEqual(spawnSync(process.execPath, [script, '--out', resolve(root, 'must-not-create-secrets')]).status, 0);
  assert.notEqual(spawnSync(process.execPath, [script, '--out', '/private/tmp/must-not-create-secrets', '--endpoint', 'http://relay.example']).status, 0);
});
test('malformed private pairing JSON never leaks its contents in errors', t => {
  const temporary = mkdtempSync(resolve(tmpdir(), 'kq-provision-private-error-'));
  t.after(() => rmSync(temporary, { recursive: true, force: true }));
  const output = resolve(temporary, 'private');
  execFileSync(process.execPath, [script, '--out', output]);
  const file = resolve(output, 'parent-1.json');
  const { readToken } = JSON.parse(readFileSync(file));
  writeFileSync(file, `private-token-${readToken}-malformed-json`, { mode: 0o600 });
  const result = spawnSync(process.execPath, [script, '--out', output, '--set-endpoint', 'https://relay.example'], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Unable to read or update the private pairing files/);
  assert.ok(!result.stdout.includes(readToken)); assert.ok(!result.stderr.includes(readToken));
  assert.ok(!result.stderr.includes('private-token-'));
});
