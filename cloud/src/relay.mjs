import { authenticate, canonical, fullMatch, MAX_BODY_BYTES, MAX_FAMILY_BYTES, record, RequestError, validateConfig, validateSnapshot, validUTC } from './validation.mjs';
import { StorageConflict, StorageUnavailable } from './storage.mjs';

function send(response, status, payload) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' });
  response.end(payload === undefined ? undefined : JSON.stringify(payload));
}
async function body(request) {
  if (request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new RequestError(415, 'content_type', 'Use application/json.');
  if (request.headers['content-encoding'] && request.headers['content-encoding'] !== 'identity') throw new RequestError(415, 'content_encoding', 'Compressed bodies are not supported.');
  if (request.headers['content-length'] && Number(request.headers['content-length']) > MAX_BODY_BYTES) throw new RequestError(413, 'body_too_large', 'The quota summary is too large.');
  let size = 0; const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new RequestError(413, 'body_too_large', 'The quota summary is too large.');
    chunks.push(chunk);
  }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))); } catch { throw new RequestError(400, 'invalid_json', 'The request is not valid JSON.'); }
}
function storedSnapshot(stored, deviceId, now) {
  if (!stored) return null;
  const fail = () => { throw new StorageUnavailable('Stored summary is invalid.'); };
  try {
    record(stored.value, ['receivedAt', 'snapshot'], [], fail);
    if (!validUTC(stored.value.receivedAt)) fail();
    validateSnapshot(stored.value.snapshot, deviceId, now);
  } catch { fail(); }
  return stored;
}
async function readLatest(storage, deviceId, now) {
  for (let attempt = 0; attempt < 4; attempt++) {
    try { return storedSnapshot(await storage.read(deviceId), deviceId, now); }
    catch (error) { if (!(error instanceof StorageConflict)) throw error; }
  }
  throw new StorageUnavailable('Storage is busy.');
}

export function createRelay({ config: rawConfig, storage, now = () => new Date() }) {
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
    try {
      if (request.url === '/healthz' && request.method === 'GET') { send(response, 200, { status: 'ok' }); return; }
      if (request.headers.origin !== undefined) throw new RequestError(403, 'origin_not_allowed', 'Browser access is not enabled.');
      const principal = authenticate(request.headers.authorization, config);
      rateLimit(principal);
      if (request.url === '/v1/family' && request.method === 'GET') {
        if (principal.role !== 'reader') throw new RequestError(403, 'read_only', 'This connection cannot read the family dashboard.');
        const date = now();
        const devices = await Promise.all(config.devices.map(async device => {
          const stored = await readLatest(storage, device.deviceId, date);
          return { deviceId: device.deviceId, deviceName: stored?.value.snapshot.deviceName ?? device.deviceName, receivedAt: stored?.value.receivedAt ?? null, snapshot: stored?.value.snapshot ?? null };
        }));
        const family = { schemaVersion: 1, familyName: config.familyName, servedAt: date.toISOString(), devices };
        if (Buffer.byteLength(JSON.stringify(family)) > MAX_FAMILY_BYTES) throw new StorageUnavailable('Family summary is too large.');
        send(response, 200, family);
        return;
      }
      const upload = fullMatch(/^\/v1\/devices\/([A-Za-z0-9_-]{1,100})\/snapshot$/, request.url);
      if (upload && request.method === 'PUT') {
        if (principal.role !== 'writer' || principal.id !== upload[1]) throw new RequestError(403, 'device_forbidden', 'This connection cannot publish that Mac.');
        const snapshot = validateSnapshot(await body(request), principal.id, now());
        for (let attempt = 0; attempt < 5; attempt++) {
          try {
            const stored = await readLatest(storage, principal.id, now());
            if (stored) {
              const order = Date.parse(snapshot.capturedAt) - Date.parse(stored.value.snapshot.capturedAt);
              if (order < 0 || (order === 0 && canonical(snapshot) !== canonical(stored.value.snapshot))) throw new RequestError(409, 'older_snapshot', 'A newer quota summary is already stored.');
              if (order === 0) { send(response, 204); return; }
            }
            await storage.write(principal.id, { receivedAt: now().toISOString(), snapshot }, stored?.generation);
            send(response, 204); return;
          } catch (error) { if (!(error instanceof StorageConflict)) throw error; }
        }
        throw new StorageUnavailable('Storage is busy.');
      }
      throw new RequestError(404, 'not_found', 'This endpoint does not exist.');
    } catch (error) {
      // Do not log request URLs, bodies, names, authorization, or provider errors.
      if (error instanceof RequestError) send(response, error.status, { error: { code: error.code, message: error.message } });
      else send(response, 503, { error: { code: 'temporarily_unavailable', message: 'Quota summaries are temporarily unavailable.' } });
    } finally {
      if (!request.complete) request.resume();
    }
  };
}
