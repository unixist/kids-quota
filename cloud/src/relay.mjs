import { authenticate, canonical, fullMatch, MAX_BODY_BYTES, MAX_FAMILY_BYTES, record, RequestError, validateConfig, validateSnapshot, validUTC } from './validation.mjs';
import { StorageConflict, StorageUnavailable } from './storage.mjs';
import { withAbort } from './cancellation.mjs';

const MAX_STORAGE_ATTEMPTS = 3;
class RequestStopped extends Error {}

function send(response, status, payload) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' });
  response.end(payload === undefined ? undefined : JSON.stringify(payload));
}
async function body(request, signal) {
  if (request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new RequestError(415, 'content_type', 'Use application/json.');
  if (request.headers['content-encoding'] && request.headers['content-encoding'] !== 'identity') throw new RequestError(415, 'content_encoding', 'Compressed bodies are not supported.');
  if (request.headers['content-length'] && Number(request.headers['content-length']) > MAX_BODY_BYTES) throw new RequestError(413, 'body_too_large', 'The quota summary is too large.');
  let size = 0; const chunks = [];
  for await (const chunk of request) {
    signal.throwIfAborted();
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new RequestError(413, 'body_too_large', 'The quota summary is too large.');
    chunks.push(chunk);
  }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))); } catch { throw new RequestError(400, 'invalid_json', 'The request is not valid JSON.'); }
}
function storedSnapshot(stored, deviceId, now) {
  if (!stored) return null;
  const fail = () => { throw new StorageUnavailable('stored_snapshot_invalid'); };
  try {
    record(stored.value, ['receivedAt', 'snapshot'], [], fail);
    if (!validUTC(stored.value.receivedAt)) fail();
    validateSnapshot(stored.value.snapshot, deviceId, now);
  } catch { fail(); }
  return stored;
}
async function readOnce(storage, deviceId, now, signal) {
  signal.throwIfAborted();
  const stored = await storage.read(deviceId, signal);
  signal.throwIfAborted();
  return storedSnapshot(stored, deviceId, now);
}
async function readLatest(storage, deviceId, now, signal) {
  for (let attempt = 0; attempt < MAX_STORAGE_ATTEMPTS; attempt++) {
    try { return await readOnce(storage, deviceId, now, signal); }
    catch (error) { if (!(error instanceof StorageConflict)) throw error; }
  }
  throw new StorageUnavailable('storage_contention');
}

export function createRelay({ config: rawConfig, storage, now = () => new Date(), requestTimeoutMs = 12000,
  logFailure = category => console.error(JSON.stringify({ event: 'quota_relay_failure', category })) }) {
  const config = validateConfig(rawConfig);
  const limits = new Map(); // Bounded by the configured credential count, never by untrusted IPs.
  const rateLimit = principal => {
    const key = `${principal.role}:${principal.id}`, time = now().getTime();
    let window = limits.get(key);
    if (!window || time < window.start || time - window.start >= 60000) window = { start: time, count: 0 };
    window.count++; limits.set(key, window);
    if (window.count > 120) throw new RequestError(429, 'rate_limited', 'Please try again shortly.');
  };
  return async (request, response) => {
    const controller = new AbortController(), { signal } = controller;
    const disconnected = () => controller.abort(new RequestStopped('client_disconnected'));
    const responseClosed = () => { if (!response.writableEnded) disconnected(); };
    request.once('aborted', disconnected);
    response.once('close', responseClosed);
    if (request.aborted || response.destroyed) disconnected();
    const timer = setTimeout(() => controller.abort(new RequestStopped('request_deadline')), requestTimeoutMs);
    const respond = (status, payload) => { signal.throwIfAborted(); send(response, status, payload); };
    const work = async () => {
      signal.throwIfAborted();
      if (request.url === '/healthz' && request.method === 'GET') { respond(200, { status: 'ok' }); return; }
      if (request.headers.origin !== undefined) throw new RequestError(403, 'origin_not_allowed', 'Browser access is not enabled.');
      const principal = authenticate(request.headers.authorization, config);
      rateLimit(principal);
      if (request.url === '/v1/family' && request.method === 'GET') {
        if (principal.role !== 'reader') throw new RequestError(403, 'read_only', 'This connection cannot read the family dashboard.');
        const date = now();
        const devices = await Promise.all(config.devices.map(async device => {
          const stored = await readLatest(storage, device.deviceId, date, signal);
          return { deviceId: device.deviceId, deviceName: stored?.value.snapshot.deviceName ?? device.deviceName, receivedAt: stored?.value.receivedAt ?? null, snapshot: stored?.value.snapshot ?? null };
        }));
        const family = { schemaVersion: 1, familyName: config.familyName, servedAt: date.toISOString(), devices };
        if (Buffer.byteLength(JSON.stringify(family)) > MAX_FAMILY_BYTES) throw new StorageUnavailable('family_too_large');
        respond(200, family);
        return;
      }
      const upload = fullMatch(/^\/v1\/devices\/([A-Za-z0-9_-]{1,100})\/snapshot$/, request.url);
      if (upload && request.method === 'PUT') {
        if (principal.role !== 'writer' || principal.id !== upload[1]) throw new RequestError(403, 'device_forbidden', 'This connection cannot publish that Mac.');
        const snapshot = validateSnapshot(await body(request, signal), principal.id, now());
        // One retry loop covers both a raced read and a raced write. Do not
        // multiply retries by calling the family-read retry loop from here.
        for (let attempt = 0; attempt < MAX_STORAGE_ATTEMPTS; attempt++) {
          try {
            const stored = await readOnce(storage, principal.id, now(), signal);
            if (stored) {
              const order = Date.parse(snapshot.capturedAt) - Date.parse(stored.value.snapshot.capturedAt);
              if (order < 0 || (order === 0 && canonical(snapshot) !== canonical(stored.value.snapshot))) throw new RequestError(409, 'older_snapshot', 'A newer quota summary is already stored.');
              if (order === 0) { respond(204); return; }
            }
            signal.throwIfAborted();
            await storage.write(principal.id, { receivedAt: now().toISOString(), snapshot }, stored?.generation, signal);
            respond(204); return;
          } catch (error) { if (!(error instanceof StorageConflict)) throw error; }
        }
        throw new StorageUnavailable('storage_contention');
      }
      throw new RequestError(404, 'not_found', 'This endpoint does not exist.');
    };
    try {
      await withAbort(work(), signal);
    } catch (error) {
      if (signal.aborted && signal.reason.message === 'client_disconnected') return;
      if (error instanceof RequestError) send(response, error.status, { error: { code: error.code, message: error.message } });
      else {
        // Only fixed categories enter logs: no request identifiers, payloads,
        // tokens, URLs, provider messages, or error stacks.
        const category = error instanceof RequestStopped && error.message === 'request_deadline' ? 'request_deadline'
          : error instanceof StorageUnavailable ? error.category : 'unexpected_failure';
        logFailure(category);
        send(response, 503, { error: { code: 'temporarily_unavailable', message: 'Quota summaries are temporarily unavailable.' } });
      }
    } finally {
      clearTimeout(timer);
      request.removeListener('aborted', disconnected);
      response.removeListener('close', responseClosed);
      // A failed family read may leave sibling reads running. Cancel those too.
      controller.abort(new RequestStopped('request_finished'));
      if (!request.complete) request.resume();
    }
  };
}
