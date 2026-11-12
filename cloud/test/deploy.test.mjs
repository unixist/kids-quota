import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { tokenDigest } from '../src/validation.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const config = {
  familyName: 'Test family', readers: [{ id: 'parent-1', name: 'Parent 1', tokenSha256: tokenDigest('r'.repeat(43)) }],
  devices: [{ deviceId: 'mac-1', deviceName: 'Kids Mac', tokenSha256: tokenDigest('w'.repeat(43)) }]
};
function environment(t, { bucketOwner = '123456789', property = 'project_number' } = {}) {
  const dir = mkdtempSync(resolve(tmpdir(), 'kq-deploy-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const bin = resolve(dir, 'bin'); mkdirSync(bin);
  const log = resolve(dir, 'calls.jsonl'), auth = resolve(dir, 'auth.json');
  writeFileSync(auth, JSON.stringify(config), { mode: 0o600 });
  const source = `#!/usr/bin/env node
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
const a=process.argv.slice(2);
appendFileSync(process.env.KQ_TEST_LOG, JSON.stringify(a)+'\\n');
if(a[0]==='projects'&&a[1]==='describe')console.log(a.some(s=>s.includes('projectNumber'))?'123456789':'kids-quota-test');
if(a[0]==='storage'&&a[1]==='buckets'&&a[2]==='describe')console.log(JSON.stringify({${JSON.stringify(property)}:${JSON.stringify(bucketOwner)}}));
if(a[0]==='builds'&&a[1]==='submit'){const f=a.find(s=>s.startsWith('--config=')).slice(9);writeFileSync(process.env.KQ_TEST_BUILD,readFileSync(f));}
if(a[0]==='run'&&a[1]==='services'&&a[2]==='describe')console.log('https://relay.example');
`;
  writeFileSync(resolve(bin, 'gcloud'), source, { mode: 0o700 });
  const run = () => spawnSync('/bin/bash', [resolve(root, 'scripts/cloud-deploy.sh'), '--project', 'kids-quota-test', '--bucket', 'kids-quota-test-private', '--region', 'us-central1', '--auth-config', auth], {
    encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, KQ_TEST_LOG: log, KQ_TEST_BUILD: resolve(dir, 'build.json') }
  });
  return { dir, auth, log, run };
}
test('deployment checks bucket ownership before changes and builds explicitly before deploying', t => {
  const { dir, log, run } = environment(t), result = run();
  assert.equal(result.status, 0, result.stderr);
  const calls = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
  const build = JSON.parse(readFileSync(resolve(dir, 'build.json')));
  assert.equal(build.options.logging, 'GCS_ONLY'); assert.equal(build.timeout, '600s');
  assert.match(build.serviceAccount, /kids-quota-build@kids-quota-test\.iam\.gserviceaccount\.com$/);
  assert.equal(build.steps[0].name, 'gcr.io/cloud-builders/docker');
  assert.equal(build.steps[0].args[0], 'build'); assert.equal(build.images[0], build.steps[0].args[2]);
  assert.ok(build.logsBucket.startsWith('gs://kids-quota-test-private-build/'));
  const buildIndex = calls.findIndex(a => a[0] === 'builds' && a[1] === 'submit');
  const deployIndex = calls.findIndex(a => a[0] === 'run' && a[1] === 'deploy');
  assert.ok(buildIndex >= 0 && deployIndex > buildIndex);
  assert.ok(!calls[buildIndex].includes('--tag'));
  assert.ok(!calls.some(a => a.includes('--role=roles/logging.logWriter')));
  assert.ok(calls.some(a => a.some(v => v.startsWith('--condition=expression=resource.name.startsWith('))));
  assert.ok(calls[deployIndex].includes('--max-instances=1'));
  assert.ok(calls[deployIndex].includes('--min-instances=0'));
  assert.ok(!JSON.stringify(calls).includes('readToken'));
});
test('deployment accepts raw camel-case bucket project numbers', t => {
  const { run } = environment(t, { property: 'projectNumber' });
  const result = run(); assert.equal(result.status, 0, result.stderr);
});
test('deployment refuses another project bucket before changing bucket settings or building', t => {
  const { run, log } = environment(t, { bucketOwner: '999999999' });
  const result = run(); assert.notEqual(result.status, 0);
  const calls = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
  assert.ok(!calls.some(a => a[0] === 'storage' && a[1] === 'buckets' && a[2] === 'update'));
  assert.ok(!calls.some(a => a[0] === 'builds' || (a[0] === 'run' && a[1] === 'deploy')));
});
test('malformed private configuration fails before any cloud calls and prints no input', t => {
  const { run, auth, log } = environment(t);
  const secret = 'private-token-do-not-log'; writeFileSync(auth, secret);
  const result = run(); assert.notEqual(result.status, 0);
  assert.ok(!result.stdout.includes(secret)); assert.ok(!result.stderr.includes(secret));
  assert.match(result.stderr, /configuration is invalid or unreadable/);
  assert.throws(() => readFileSync(log));
});
