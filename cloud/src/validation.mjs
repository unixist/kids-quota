import { createHash, timingSafeEqual } from 'node:crypto';

export const MAX_BODY_BYTES = 128 * 1024;
export const MAX_FAMILY_BYTES = 4 * 1024 * 1024;
export const MAX_DEVICES = 20;
const idPattern = /^[A-Za-z0-9_-]{1,100}$/;
const utcPattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;
const maximumSeconds = 604800000;

export class RequestError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
const invalid = () => { throw new RequestError(422, 'invalid_snapshot', 'The quota summary is invalid.'); };
export function record(value, required, optional = [], fail = invalid) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail();
  const keys = Object.keys(value);
  if (required.some(k => !Object.hasOwn(value, k)) || keys.some(k => !required.includes(k) && !optional.includes(k))) fail();
}
// JavaScript's `$` can match before a final newline. Require the matched text to
// consume the entire string wherever a value or credential must be exact.
export function fullMatch(pattern, value) {
  if (typeof value !== 'string') return null;
  const match = pattern.exec(value);
  return match && match[0].length === value.length ? match : null;
}
export function validID(value) { return Boolean(fullMatch(idPattern, value)); }
export function validText(value, max = 100) {
  return typeof value === 'string' && value.length > 0 && value.length <= max && value.trim() === value && !/[\u0000-\u001f\u007f]/.test(value);
}
export function validUTC(value) {
  if (!fullMatch(utcPattern, value) || !Number.isFinite(Date.parse(value))) return false;
  // Date.parse normalizes impossible calendar days; reject those explicitly.
  return new Date(value).toISOString().slice(0, 19) === value.slice(0, 19);
}
export function validEndpoint(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash && (url.pathname === '/' || url.pathname === '') && !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  } catch { return false; }
}
export function tokenDigest(token) { return createHash('sha256').update(token).digest('hex'); }

export function validateConfig(input) {
  const fail = () => { throw new Error('Invalid KQ_AUTH_CONFIG; inspect the private configuration file.'); };
  record(input, ['familyName', 'readers', 'devices'], [], fail);
  if (!validText(input.familyName) || !Array.isArray(input.readers) || input.readers.length < 1 || input.readers.length > 20 || !Array.isArray(input.devices) || input.devices.length < 1 || input.devices.length > MAX_DEVICES) fail();
  const hashes = new Set(), readers = new Set(), devices = new Set();
  for (const entry of input.readers) {
    record(entry, ['id', 'name', 'tokenSha256'], [], fail);
    if (!validID(entry.id) || readers.has(entry.id) || !validText(entry.name)) fail();
    readers.add(entry.id);
  }
  for (const entry of input.devices) {
    record(entry, ['deviceId', 'deviceName', 'tokenSha256'], [], fail);
    if (!validID(entry.deviceId) || devices.has(entry.deviceId) || !validText(entry.deviceName)) fail();
    devices.add(entry.deviceId);
  }
  for (const entry of [...input.readers, ...input.devices]) {
    if (!fullMatch(/^[a-f0-9]{64}$/, entry.tokenSha256) || hashes.has(entry.tokenSha256)) fail();
    hashes.add(entry.tokenSha256);
  }
  return structuredClone(input);
}

export function authenticate(header, config) {
  const match = fullMatch(/^Bearer ([A-Za-z0-9_-]{32,512})$/, header);
  if (!match) throw new RequestError(401, 'unauthorized', 'A valid connection is required.');
  const digest = Buffer.from(tokenDigest(match[1]), 'hex');
  let principal;
  for (const entry of config.readers) {
    if (timingSafeEqual(digest, Buffer.from(entry.tokenSha256, 'hex'))) principal = { role: 'reader', id: entry.id };
  }
  for (const entry of config.devices) {
    if (timingSafeEqual(digest, Buffer.from(entry.tokenSha256, 'hex'))) principal = { role: 'writer', id: entry.deviceId };
  }
  if (!principal) throw new RequestError(401, 'unauthorized', 'A valid connection is required.');
  return principal;
}

export function validateSnapshot(input, deviceId, now = new Date()) {
  record(input, ['schemaVersion', 'deviceId', 'deviceName', 'capturedAt', 'resetTimeZone', 'children']);
  if (input.schemaVersion !== 1 || input.deviceId !== deviceId || !validID(input.deviceId) || !validText(input.deviceName) || !validUTC(input.capturedAt) || Date.parse(input.capturedAt) > now.getTime() + 300000) invalid();
  if (!validText(input.resetTimeZone, 100)) invalid();
  try { new Intl.DateTimeFormat('en-US', { timeZone: input.resetTimeZone }); } catch { invalid(); }
  if (!Array.isArray(input.children) || input.children.length > 20) invalid();
  const childIds = new Set();
  for (const child of input.children) {
    record(child, ['id', 'name', 'balances']);
    if (!validID(child.id) || childIds.has(child.id) || !validText(child.name) || !Array.isArray(child.balances) || child.balances.length > 50) invalid();
    childIds.add(child.id);
    const quotas = new Set(), services = new Set();
    for (const balance of child.balances) {
      record(balance, ['quotaId', 'serviceId', 'serviceName', 'domains', 'limitSeconds', 'usedSeconds', 'remainingSeconds', 'periodStart', 'periodEnd', 'quotaState', 'coverage'], ['blockingReason']);
      if (!validID(balance.quotaId) || quotas.has(balance.quotaId) || !validID(balance.serviceId) || services.has(balance.serviceId) || !validText(balance.serviceName)) invalid();
      quotas.add(balance.quotaId); services.add(balance.serviceId);
      if (!Array.isArray(balance.domains) || balance.domains.length > 50 || new Set(balance.domains).size !== balance.domains.length) invalid();
      for (const domain of balance.domains) {
        if (typeof domain !== 'string' || domain.length > 253 || !fullMatch(/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/, domain) || fullMatch(/^\d+\.\d+\.\d+\.\d+$/, domain)) invalid();
      }
      if (!Number.isSafeInteger(balance.limitSeconds) || balance.limitSeconds < 0 || balance.limitSeconds > maximumSeconds || !Number.isSafeInteger(balance.usedSeconds) || balance.usedSeconds < 0 || !Number.isSafeInteger(balance.remainingSeconds) || balance.remainingSeconds < 0 || balance.remainingSeconds !== Math.max(0, balance.limitSeconds - balance.usedSeconds)) invalid();
      if (!validUTC(balance.periodStart) || !validUTC(balance.periodEnd) || Date.parse(balance.periodStart) >= Date.parse(balance.periodEnd) || Date.parse(balance.periodStart) > Date.parse(input.capturedAt) || Date.parse(balance.periodEnd) <= Date.parse(input.capturedAt)) invalid();
      if (balance.quotaState !== (balance.remainingSeconds === 0 ? 'exhausted' : 'available') || !['complete', 'incomplete'].includes(balance.coverage)) invalid();
      if (balance.blockingReason !== undefined) {
        if (!['available', 'exhausted', 'collector_unavailable'].includes(balance.blockingReason)) invalid();
        if ((balance.blockingReason === 'exhausted' && balance.remainingSeconds !== 0) || (balance.blockingReason === 'available' && balance.remainingSeconds === 0)) invalid();
      }
    }
  }
  return structuredClone(input);
}

export function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  return JSON.stringify(value);
}
