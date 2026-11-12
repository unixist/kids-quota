import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { EventEmitter } from 'node:events';
import { createRelay } from '../src/relay.mjs';
import { GCSStorage, MetadataCredentials, StorageConflict, StorageUnavailable } from '../src/storage.mjs';
import { authenticate, canonical, MAX_BODY_BYTES, tokenDigest, validateConfig, validateSnapshot, validEndpoint, validID, validUTC } from '../src/validation.mjs';

const reader = 'r'.repeat(43), reader2 = 's'.repeat(43), writer = 'w'.repeat(43), writer2 = 'x'.repeat(43);
const now = () => new Date('2026-11-12T02:10:00Z');
const config = {
  familyName: 'Our family',
  readers: [{ id: 'parent-1', name: 'Parent 1', tokenSha256: tokenDigest(reader) }, { id: 'parent-2', name: 'Parent 2', tokenSha256: tokenDigest(reader2) }],
  devices: [{ deviceId: 'mac-1', deviceName: 'Kids Mac', tokenSha256: tokenDigest(writer) }, { deviceId: 'mac-2', deviceName: 'Second Mac', tokenSha256: tokenDigest(writer2) }]
};
const summary = () => ({
  schemaVersion: 1, deviceId: 'mac-1', deviceName: 'Kids Mac', capturedAt: '2026-11-12T02:00:00Z', resetTimeZone: 'America/Chicago',
  children: [{ id: 'child-1', name: 'Alex', balances: [{ quotaId: 'q-1', serviceId: 'chess', serviceName: 'Chess.com', domains: ['chess.com'], limitSeconds: 21600, usedSeconds: 3600, remainingSeconds: 18000, periodStart: '2026-11-09T06:00:00Z', periodEnd: '2026-11-16T06:00:00Z', quotaState: 'available', coverage: 'complete', blockingReason: 'available' }] }]
});
class MemoryStorage {
  values = new Map(); sequence = 0; failures = false; beforeWrite = null;
  async read(id) { if (this.failures) throw new StorageUnavailable(); return structuredClone(this.values.get(id) ?? null); }
  async write(id, value, generation) {
    if (this.beforeWrite) { const callback = this.beforeWrite; this.beforeWrite = null; await callback(); }
    if ((this.values.get(id)?.generation ?? undefined) !== generation) throw new StorageConflict();
    this.values.set(id, { generation: String(++this.sequence), value: structuredClone(value) });
  }
}
function setup(custom = {}) {
  const storage = custom.storage ?? new MemoryStorage();
  const logs = [];
  const handler = createRelay({ config: custom.config ?? config, storage, now: custom.now ?? now,
    requestTimeoutMs: custom.requestTimeoutMs, logFailure: category => logs.push(category) });
  async function request({ method = 'GET', url = '/v1/family', token = reader, body, headers = {}, raw, onRequest } = {}) {
    const source = raw ?? (body === undefined ? '' : JSON.stringify(body));
    const input = Readable.from([Buffer.from(source)]);
    input.method = method; input.url = url; input.complete = true;
    input.headers = { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined || raw !== undefined ? { 'content-type': 'application/json' } : {}), ...headers };
    let status, output, responseHeaders;
    const response = Object.assign(new EventEmitter(), {
      writeHead(code, h) { status = code; responseHeaders = h; },
      end(value) { output = value; this.writableEnded = true; }
    });
    const pending = handler(input, response);
    onRequest?.(input, response);
    await pending;
    return { status, headers: responseHeaders, body: output ? JSON.parse(output) : null };
  }
  const upload = (body = summary(), token = writer) => request({ method: 'PUT', url: `/v1/devices/${body.deviceId}/snapshot`, token, body });
  return { request, upload, storage, logs };
}

test('health exposes only liveness; all family access needs authentication', async () => {
  const { request } = setup();
  assert.deepEqual((await request({ url: '/healthz', token: null })).body, { status: 'ok' });
  for (const token of [null, 'wrong'.repeat(10), reader + ' ']) assert.equal((await request({ token })).status, 401);
});
test('each parent can read all configured Macs, including Macs not yet reporting', async () => {
  const { request } = setup();
  for (const token of [reader, reader2]) {
    const result = await request({ token });
    assert.equal(result.status, 200); assert.equal(result.body.devices.length, 2);
    assert.equal(result.body.devices[0].snapshot, null); assert.equal(result.body.devices[0].receivedAt, null);
    assert.equal(result.headers['Cache-Control'], 'no-store');
    assert.ok(!JSON.stringify(result.body).includes('tokenSha256'));
  }
});
test('read-only phone credentials cannot upload; Mac cannot read family or another Mac', async () => {
  const { request, upload } = setup();
  assert.equal((await upload(summary(), reader)).status, 403);
  assert.equal((await upload(summary(), writer2)).status, 403);
  assert.equal((await request({ token: writer })).status, 403);
});
test('uploads retain exact summaries and server receipt time', async () => {
  const { request, upload } = setup();
  assert.equal((await upload()).status, 204);
  const result = await request();
  assert.deepEqual(result.body.devices[0].snapshot, summary());
  assert.equal(result.body.devices[0].receivedAt, now().toISOString());
});
test('missing monitor remains separate from exhausted allowance', async () => {
  const { request, upload } = setup(), value = summary();
  value.children[0].balances[0].blockingReason = 'collector_unavailable';
  value.children[0].balances[0].coverage = 'incomplete';
  assert.equal((await upload(value)).status, 204);
  const balance = (await request()).body.devices[0].snapshot.children[0].balances[0];
  assert.equal(balance.remainingSeconds, 18000); assert.equal(balance.quotaState, 'available');
  assert.equal(balance.blockingReason, 'collector_unavailable');
});
test('zero allowance and used time exceeding allowance are valid exhausted balances', () => {
  const value = summary(), balance = value.children[0].balances[0];
  balance.limitSeconds = 0; balance.usedSeconds = 700000000; balance.remainingSeconds = 0;
  balance.quotaState = 'exhausted'; balance.blockingReason = 'exhausted';
  assert.equal(validateSnapshot(value, 'mac-1', now()).children[0].balances[0].usedSeconds, 700000000);
});
test('identical retry is idempotent; old or conflicting same-time updates cannot replace state', async () => {
  const { upload, storage } = setup();
  assert.equal((await upload()).status, 204);
  const generation = storage.values.get('mac-1').generation;
  assert.equal((await upload()).status, 204);
  assert.equal(storage.values.get('mac-1').generation, generation);
  const earlier = summary(); earlier.capturedAt = '2026-11-12T01:59:00Z';
  assert.equal((await upload(earlier)).status, 409);
  const conflict = summary(); conflict.deviceName = 'Changed name';
  assert.equal((await upload(conflict)).status, 409);
});
test('generation race retries and cannot overwrite a newer concurrent upload', async () => {
  const { upload, storage } = setup();
  const newer = summary(); newer.capturedAt = '2026-11-12T02:05:00Z';
  storage.beforeWrite = async () => storage.write('mac-1', { receivedAt: now().toISOString(), snapshot: newer });
  assert.equal((await upload()).status, 409);
  assert.deepEqual(storage.values.get('mac-1').value.snapshot, newer);
});
test('generation race can retry over an older concurrent upload', async () => {
  const { upload, storage } = setup();
  const earlier = summary(); earlier.capturedAt = '2026-11-12T01:59:00Z';
  storage.beforeWrite = async () => storage.write('mac-1', { receivedAt: now().toISOString(), snapshot: earlier });
  assert.equal((await upload()).status, 204);
  assert.deepEqual(storage.values.get('mac-1').value.snapshot, summary());
});
test('generation contention is bounded', async () => {
  let reads = 0, writes = 0;
  const storage = { read: async () => { reads++; return null; }, write: async () => { writes++; throw new StorageConflict(); } };
  const value = setup({ storage });
  assert.equal((await value.upload()).status, 503);
  assert.equal(reads, 3); assert.equal(writes, 3);
  assert.deepEqual(value.logs, ['storage_contention']);
});
test('raced reads and writes share one three-attempt upload budget', async () => {
  let reads = 0, writes = 0;
  const storage = {
    read: async () => { if (++reads < 3) throw new StorageConflict(); return null; },
    write: async () => { writes++; throw new StorageConflict(); }
  };
  assert.equal((await setup({ storage }).upload()).status, 503);
  assert.equal(reads, 3); assert.equal(writes, 1);
});
test('storage failures never return a misleading partial family', async () => {
  const { request, upload, storage } = setup(); await upload();
  const original = storage.read.bind(storage);
  storage.read = async id => { if (id === 'mac-2') throw new StorageUnavailable(); return original(id); };
  const result = await request(); assert.equal(result.status, 503); assert.equal(result.body.devices, undefined);
});
test('corrupt stored snapshots fail closed without leaking provider diagnostics', async () => {
  const { request, storage, logs } = setup();
  storage.values.set('mac-1', { generation: '1', value: { receivedAt: now().toISOString(), snapshot: { privateData: 'secret' } } });
  const result = await request(); assert.equal(result.status, 503); assert.ok(!JSON.stringify(result).includes('secret'));
  assert.deepEqual(logs, ['stored_snapshot_invalid']);
});
test('no CORS and no remote administration endpoints', async () => {
  const { request } = setup();
  assert.equal((await request({ headers: { origin: 'https://evil.example' } })).status, 403);
  assert.equal((await request({ method: 'POST', url: '/v1/admin/reset' })).status, 404);
  assert.equal((await request({ url: '/v1/family?token=anything' })).status, 404);
});
test('invalid JSON, types, oversized content and compression are rejected', async () => {
  const { request } = setup();
  const base = { method: 'PUT', url: '/v1/devices/mac-1/snapshot', token: writer };
  assert.equal((await request({ ...base, raw: '{' })).status, 400);
  assert.equal((await request({ ...base, raw: '{}', headers: { 'content-type': 'text/plain' } })).status, 415);
  assert.equal((await request({ ...base, raw: '{}', headers: { 'content-encoding': 'gzip' } })).status, 415);
  assert.equal((await request({ ...base, raw: '{}', headers: { 'content-length': String(MAX_BODY_BYTES + 1) } })).status, 413);
  assert.equal((await request({ ...base, raw: ' '.repeat(MAX_BODY_BYTES + 1) })).status, 413);
});
test('a malformed second child rejects the entire upload and preserves previous data', async () => {
  const { upload, storage } = setup(); await upload();
  const bad = summary(); bad.capturedAt = '2026-11-12T02:05:00Z'; bad.children.push({ id: 'bad', name: 'Bad', balances: [{ bad: true }] });
  assert.equal((await upload(bad)).status, 422);
  assert.equal(storage.values.get('mac-1').value.snapshot.children.length, 1);
});
test('unknown fields reject attempted browser history and local identities at every level', () => {
  for (const mutate of [s => s.browserHistory = [], s => s.children[0].uid = 501, s => s.children[0].balances[0].appPath = '/Applications/Chess.app']) {
    const value = summary(); mutate(value); assert.throws(() => validateSnapshot(value, 'mac-1', now()));
  }
});
test('domain URLs, IPs, malformed identities and duplicate children or quotas are rejected', () => {
  for (const mutate of [s => s.children[0].balances[0].domains = ['https://chess.com/private'], s => s.children[0].balances[0].domains = ['127.0.0.1'], s => s.children[0].id = '../escape', s => s.children.push(structuredClone(s.children[0])), s => s.children[0].balances.push(structuredClone(s.children[0].balances[0]))]) {
    const value = summary(); mutate(value); assert.throws(() => validateSnapshot(value, 'mac-1', now()));
  }
});
test('invalid timezone, impossible date, future capture, periods and balance inconsistency are rejected', () => {
  for (const mutate of [s => s.resetTimeZone = 'not/a/zone', s => s.capturedAt = '2026-02-30T00:00:00Z', s => s.capturedAt = '2026-11-12T02:16:00Z', s => s.children[0].balances[0].remainingSeconds = 100, s => s.children[0].balances[0].usedSeconds = -1, s => s.children[0].balances[0].periodEnd = s.capturedAt, s => s.children[0].balances[0].quotaState = 'exhausted']) {
    const value = summary(); mutate(value); assert.throws(() => validateSnapshot(value, 'mac-1', now()));
  }
});
test('older valid snapshot stays readable after a weekly boundary; relay invents no reset', async () => {
  const { upload, storage } = setup(); await upload();
  const saved = structuredClone(storage.values.get('mac-1').value.snapshot);
  assert.deepEqual(validateSnapshot(saved, 'mac-1', new Date('2026-12-20T00:00:00Z')), saved);
});
test('credential revocation takes effect with replacement runtime config', async () => {
  const revoked = structuredClone(config); revoked.readers = revoked.readers.filter(r => r.id !== 'parent-1');
  const { request } = setup({ config: revoked });
  assert.equal((await request({ token: reader })).status, 401); assert.equal((await request({ token: reader2 })).status, 200);
});
test('configuration rejects duplicate credentials, IDs, unknown fields and empty families', () => {
  for (const mutate of [c => c.devices[0].tokenSha256 = c.readers[0].tokenSha256, c => c.devices.push(structuredClone(c.devices[0])), c => c.readers = [], c => c.token = 'plaintext']) {
    const value = structuredClone(config); mutate(value); assert.throws(() => validateConfig(value));
  }
});
test('rate limits are per configured credential and have bounded cardinality', async () => {
  const { request } = setup();
  for (let i = 0; i < 120; i++) assert.equal((await request()).status, 200);
  assert.equal((await request()).status, 429);
  assert.equal((await request({ token: reader2 })).status, 200);
});
test('canonical equality ignores object key order and date validation is strict', () => {
  assert.equal(canonical({ b: 2, a: 1 }), canonical({ a: 1, b: 2 }));
  assert.equal(validUTC('2026-11-12T02:00:00.123Z'), true);
  assert.equal(validUTC('2026-11-12T02:00:00-06:00'), false);
  assert.equal(validUTC('2026-02-30T02:00:00Z'), false);
});
test('identifiers, dates, token hashes, and bearer headers reject final newlines', () => {
  for (const suffix of ['\n', '\r', '\r\n', '\u2028', '\u2029']) {
    assert.equal(validID(`mac-1${suffix}`), false);
    assert.equal(validUTC(`2026-11-12T02:00:00Z${suffix}`), false);
    const badConfig = structuredClone(config); badConfig.readers[0].tokenSha256 += suffix;
    assert.throws(() => validateConfig(badConfig));
    assert.throws(() => authenticate(`Bearer ${reader}${suffix}`, config));
    const badSnapshot = summary(); badSnapshot.children[0].balances[0].domains = [`chess.com${suffix}`];
    assert.throws(() => validateSnapshot(badSnapshot, 'mac-1', now()));
    assert.throws(() => new GCSStorage(`test-bucket${suffix}`));
  }
});
test('upload route rejects a final newline instead of accepting a prefix', async () => {
  const { request } = setup();
  const result = await request({ method: 'PUT', url: '/v1/devices/mac-1/snapshot\n', token: writer, body: summary() });
  assert.equal(result.status, 404);
});
test('rate-limit windows recover when the wall clock moves backwards', async () => {
  let instant = now();
  const { request } = setup({ now: () => instant });
  for (let i = 0; i < 120; i++) assert.equal((await request()).status, 200);
  assert.equal((await request()).status, 429);
  instant = new Date(instant.getTime() - 1000);
  assert.equal((await request()).status, 200);
});
test('pairing endpoints must be HTTPS origins without embedded credentials or path', () => {
  assert.ok(validEndpoint('https://relay.example'));
  for (const value of ['http://relay.example', 'https://user:secret@relay.example', 'https://relay.example/path', 'https://relay.example?token=secret', 'https://relay.example/#fragment', 'https://localhost']) assert.equal(validEndpoint(value), false);
});

test('GCS reads pin the generation and do not follow redirects with credentials', async () => {
  const calls = [], value = { receivedAt: now().toISOString(), snapshot: summary() };
  const store = new GCSStorage('test-bucket', { credentials: { token: async () => 'short-lived' }, fetcher: async (url, options) => {
    calls.push({ url, options });
    return new Response(JSON.stringify(calls.length === 1 ? { generation: '12', size: '999' } : value), { status: 200 });
  } });
  assert.deepEqual(await store.read('mac-1'), { generation: '12', value });
  assert.match(calls[1].url, /generation=12/);
  for (const call of calls) { assert.equal(call.options.redirect, 'error'); assert.equal(call.options.headers.Authorization, 'Bearer short-lived'); }
});
test('GCS missing objects are empty, while generation races are retryable conflicts', async () => {
  const credentials = { token: async () => 'token' };
  assert.equal(await new GCSStorage('test-bucket', { credentials, fetcher: async () => new Response(null, { status: 404 }) }).read('mac-1'), null);
  let call = 0;
  const store = new GCSStorage('test-bucket', { credentials, fetcher: async () => ++call === 1 ? new Response(JSON.stringify({ generation: '1', size: '9' })) : new Response(null, { status: 404 }) });
  await assert.rejects(store.read('mac-1'), StorageConflict);
});
test('GCS create and replacement both use generation preconditions', async () => {
  const calls = [], credentials = { token: async () => 'token' };
  const store = new GCSStorage('test-bucket', { credentials, fetcher: async (url, options) => { calls.push({ url, options }); return new Response('{}'); } });
  await store.write('mac-1', {}, undefined); await store.write('mac-1', {}, '123');
  assert.match(calls[0].url, /ifGenerationMatch=0$/); assert.match(calls[1].url, /ifGenerationMatch=123$/);
  const busy = new GCSStorage('test-bucket', { credentials, fetcher: async () => new Response(null, { status: 412 }) });
  await assert.rejects(busy.write('mac-1', {}, '123'), StorageConflict);
});
test('metadata credentials are short-lived, cached, coalesced, and refresh before expiry', async () => {
  let calls = 0, time = 0;
  const credentials = new MetadataCredentials(async (url, options) => {
    calls++; assert.equal(url, 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token');
    assert.equal(options.headers['Metadata-Flavor'], 'Google'); assert.equal(options.redirect, 'error');
    return new Response(JSON.stringify({ access_token: `token-${calls}`, expires_in: 3600 }), { headers: { 'Metadata-Flavor': 'Google' } });
  }, () => time);
  assert.deepEqual(await Promise.all([credentials.token(), credentials.token()]), ['token-1', 'token-1']);
  assert.equal(calls, 1); time = 3550000; assert.equal(await credentials.token(), 'token-2');
});
test('metadata failures do not poison later credential retries', async () => {
  let count = 0;
  const credentials = new MetadataCredentials(async () => ++count === 1 ? new Response('no', { status: 503 }) : new Response(JSON.stringify({ access_token: 'token', expires_in: 3600 }), { headers: { 'Metadata-Flavor': 'Google' } }));
  await assert.rejects(credentials.token()); assert.equal(await credentials.token(), 'token');
});

function untilAborted(signal) {
  return new Promise((resolve, reject) => {
    if (signal.aborted) reject(signal.reason);
    else signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  });
}
const tick = () => new Promise(resolve => setImmediate(resolve));

test('one request deadline cancels coalesced metadata fetches and returns a private 503', async () => {
  const signals = [];
  const credentials = new MetadataCredentials(async (_url, options) => { signals.push(options.signal); return untilAborted(options.signal); });
  const storage = new GCSStorage('test-bucket', { credentials, fetcher: async () => assert.fail('Storage must wait for identity.') });
  const { request, logs } = setup({ storage, requestTimeoutMs: 25 });
  const result = await request();
  await tick();
  assert.equal(result.status, 503);
  assert.deepEqual(logs, ['request_deadline']);
  assert.equal(signals.length, 1); assert.equal(signals[0].aborted, true);
  assert.equal(credentials.pending.size, 0); assert.equal(credentials.cached, null);
});

test('the same total deadline covers storage headers and snapshot body reads', async () => {
  for (const stallBody of [false, true]) {
    const signals = [];
    const storage = new GCSStorage('test-bucket', { credentials: { token: async () => 'private-access-token' }, fetcher: async (url, options) => {
      signals.push(options.signal);
      if (!stallBody) return untilAborted(options.signal);
      if (url.includes('fields=')) return new Response(JSON.stringify({ generation: '1', size: '100' }));
      return { ok: true, status: 200, json: () => untilAborted(options.signal) };
    } });
    const { request, logs } = setup({ storage, requestTimeoutMs: 25 });
    assert.equal((await request()).status, 503);
    assert.deepEqual(logs, ['request_deadline']);
    assert.ok(signals.length >= 2);
    assert.ok(signals.every(signal => signal === signals[0] && signal.aborted));
  }
});

test('client disconnection cancels an in-flight GCS upload without another response', async () => {
  let markStarted, response, requestInput, writeSignal;
  const started = new Promise(resolve => { markStarted = resolve; });
  const storage = new GCSStorage('test-bucket', { credentials: { token: async () => 'private-access-token' }, fetcher: async (url, options) => {
    if (!url.includes('/upload/')) return new Response(null, { status: 404 });
    writeSignal = options.signal; markStarted(); return untilAborted(options.signal);
  } });
  const { request, logs } = setup({ storage });
  const pending = request({ method: 'PUT', url: '/v1/devices/mac-1/snapshot', token: writer, body: summary(), onRequest(input, output) {
    response = output; requestInput = input;
  } });
  await started;
  // IncomingMessage's normal close after its body is consumed must not cancel
  // storage work while the response is still being prepared.
  requestInput.emit('close');
  assert.equal(writeSignal.aborted, false);
  response.destroyed = true; response.emit('close');
  const result = await pending;
  assert.equal(writeSignal.aborted, true); assert.equal(result.status, undefined);
  assert.deepEqual(logs, []);
});

test('aborted request bodies cancel request work and never publish', async () => {
  let writes = 0, signal;
  const storage = { read: async (_id, received) => { signal = received; return untilAborted(received); }, write: async () => { writes++; } };
  const { request, logs } = setup({ storage });
  const result = await request({ onRequest(input) { input.aborted = true; input.emit('aborted'); } });
  assert.equal(result.status, undefined); assert.equal(signal.aborted, true); assert.equal(writes, 0);
  assert.deepEqual(logs, []);
});

test('a late read after deadline cannot start an upload or write a second response', async () => {
  let release, writes = 0;
  const storage = { read: () => new Promise(resolve => { release = resolve; }), write: async () => { writes++; } };
  const { upload, logs } = setup({ storage, requestTimeoutMs: 25 });
  assert.equal((await upload()).status, 503);
  release(null); await tick();
  assert.equal(writes, 0); assert.deepEqual(logs, ['request_deadline']);
});

test('one client cancellation does not cancel another metadata refresh', async () => {
  const first = new AbortController(), second = new AbortController(), calls = [];
  const credentials = new MetadataCredentials((_url, options) => new Promise((resolve, reject) => {
    calls.push({ signal: options.signal, resolve });
    options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
  }));
  const firstToken = credentials.token(first.signal), otherFirstToken = credentials.token(first.signal), secondToken = credentials.token(second.signal);
  const canceled = Promise.all([assert.rejects(firstToken), assert.rejects(otherFirstToken)]);
  assert.equal(calls.length, 2);
  first.abort(new Error('disconnected')); await canceled;
  assert.equal(calls[0].signal.aborted, true); assert.equal(calls[1].signal.aborted, false);
  calls[1].resolve(new Response(JSON.stringify({ access_token: 'second-token', expires_in: 3600 }), { headers: { 'Metadata-Flavor': 'Google' } }));
  assert.equal(await secondToken, 'second-token'); assert.equal(credentials.pending.size, 0);
  assert.equal(await credentials.token(), 'second-token');
});

test('internal diagnostics contain only fixed categories, never errors, credentials, or payloads', async () => {
  const secret = `https://private.example/?token=${writer} Child Alex provider failure`;
  for (const [error, expected] of [[new Error(secret), 'unexpected_failure'], [new StorageUnavailable(secret), 'storage_unavailable']]) {
    const { request, logs } = setup({ storage: { read: async () => { throw error; } } });
    const result = await request();
    assert.equal(result.status, 503); assert.deepEqual(logs, [expected]);
    assert.ok(!JSON.stringify({ result, logs }).includes(secret));
  }
  const cases = [
    ['identity_unavailable', new GCSStorage('test-bucket', { fetcher: async () => { throw new Error(secret); } }), false],
    ['storage_read_failed', new GCSStorage('test-bucket', { credentials: { token: async () => secret }, fetcher: async () => new Response(secret, { status: 403 }) }), false],
    ['storage_write_failed', new GCSStorage('test-bucket', { credentials: { token: async () => secret }, fetcher: async url => new Response(secret, { status: url.includes('/upload/') ? 503 : 404 }) }), true],
    ['stored_snapshot_invalid', new GCSStorage('test-bucket', { credentials: { token: async () => secret }, fetcher: async () => new Response(secret) }), false]
  ];
  for (const [expected, storage, isUpload] of cases) {
    const { request, upload, logs } = setup({ storage });
    const result = await (isUpload ? upload() : request());
    assert.equal(result.status, 503); assert.deepEqual(logs, [expected]);
    assert.ok(!JSON.stringify({ result, logs }).includes(writer));
    assert.ok(!JSON.stringify({ result, logs }).includes('private.example'));
  }
});
