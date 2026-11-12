#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { closeSync, constants, fstatSync, lstatSync, openSync, readFileSync, realpathSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { fullMatch, MAX_FAMILY_BYTES, record, validEndpoint, validID, validText } from '../cloud/src/validation.mjs';

class SafeError extends Error {}
const root = realpathSync(resolve(dirname(fileURLToPath(import.meta.url)), '..'));
const reservedHosts = ['invalid', 'example', 'test', 'localhost', 'example.com', 'example.net', 'example.org'];
function safeError() { throw new SafeError('Connection files must be valid private pairing documents for the same deployed HTTPS service.'); }

function readPrivateDocument(file) {
  try {
    if (typeof file !== 'string' || !isAbsolute(file)) safeError();
    const path = resolve(file), folder = dirname(path);
    const fileInfo = lstatSync(path), folderInfo = lstatSync(folder);
    if (fileInfo.isSymbolicLink() || folderInfo.isSymbolicLink() || !fileInfo.isFile() || !folderInfo.isDirectory()) safeError();
    if ((fileInfo.mode & 0o777) !== 0o600 || (folderInfo.mode & 0o777) !== 0o700 || fileInfo.uid !== process.getuid() || folderInfo.uid !== process.getuid()) safeError();
    const relation = relative(root, realpathSync(path));
    if (!relation || (!relation.startsWith(`..${sep}`) && relation !== '..' && !isAbsolute(relation))) safeError();
    if (process.platform === 'darwin') {
      for (const target of [path, folder]) {
        const listing = execFileSync('/bin/ls', ['-lde', target], { encoding: 'utf8', maxBuffer: 16384, timeout: 5000 });
        if (/^\s*\d+:/m.test(listing)) safeError();
      }
    }
    const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const actual = fstatSync(descriptor);
      if (!actual.isFile() || actual.ino !== fileInfo.ino || actual.dev !== fileInfo.dev || actual.size > 16384 || actual.uid !== process.getuid() || (actual.mode & 0o777) !== 0o600) safeError();
      return JSON.parse(readFileSync(descriptor, 'utf8'));
    } finally { closeSync(descriptor); }
  } catch { safeError(); }
}

export function loadConnections(parentFile, macFile) {
  const parent = readPrivateDocument(parentFile), mac = readPrivateDocument(macFile);
  try {
    record(parent, ['schemaVersion', 'endpoint', 'familyName', 'readToken'], [], safeError);
    record(mac, ['schemaVersion', 'endpoint', 'deviceId', 'deviceName', 'writeToken'], [], safeError);
    if (parent.schemaVersion !== 1 || mac.schemaVersion !== 1 || !validText(parent.familyName) || !validText(mac.deviceName) || !validID(mac.deviceId)) safeError();
    for (const document of [parent, mac]) {
      if (!validEndpoint(document.endpoint)) safeError();
      const url = new URL(document.endpoint), host = url.hostname.toLowerCase().replace(/\.$/, '');
      const authority = document.endpoint.split('/')[2];
      if (document.endpoint !== document.endpoint.trim() || /[\s\\]/.test(document.endpoint) || authority?.endsWith(':') || (url.port && Number(url.port) < 1)) safeError();
      if (reservedHosts.some(name => host === name || host.endsWith(`.${name}`))) safeError();
    }
    if (!fullMatch(/^[A-Za-z0-9_-]{32,512}$/, parent.readToken) || !fullMatch(/^[A-Za-z0-9_-]{32,512}$/, mac.writeToken) || parent.readToken === mac.writeToken) safeError();
    const endpoint = new URL(parent.endpoint).origin;
    if (endpoint !== new URL(mac.endpoint).origin) safeError();
    return { endpoint, parent, mac };
  } catch { safeError(); }
}

async function readJSON(response) {
  const reader = response.body?.getReader();
  if (!reader) throw new SafeError('The dashboard response is invalid.');
  const chunks = []; let bytes = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > MAX_FAMILY_BYTES) throw new SafeError('The dashboard response is too large.');
      chunks.push(Buffer.from(value));
    }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)));
  } catch { throw new SafeError('The dashboard response is invalid or too large.'); }
  finally { await reader.cancel().catch(() => {}); }
}

export async function runSmoke(connections, { fetcher = fetch, report = console.log } = {}) {
  const { endpoint, parent, mac } = connections;
  async function check(label, path, expected, { token, method = 'GET', body, json = false } = {}) {
    let response;
    try {
      response = await fetcher(`${endpoint}${path}`, {
        method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}) },
        body, redirect: 'error', signal: AbortSignal.timeout(20000)
      });
    } catch { throw new SafeError(`${label}: the service could not be reached securely.`); }
    if (response.status !== expected) {
      await response.body?.cancel().catch(() => {});
      throw new SafeError(`${label}: expected HTTP ${expected}, received HTTP ${response.status}.`);
    }
    const value = json ? await readJSON(response) : null;
    if (!json) await response.body?.cancel().catch(() => {});
    report(`${label}: HTTP ${response.status}`);
    return value;
  }
  await check('Service health', '/healthz', 200);
  await check('Anonymous access rejected', '/v1/family', 401);
  const family = await check('Parent dashboard access', '/v1/family', 200, { token: parent.readToken, json: true });
  if (family?.schemaVersion !== 1 || !Array.isArray(family.devices) || family.devices.length > 20 || !family.devices.some(device => device.deviceId === mac.deviceId)) throw new SafeError('The dashboard does not contain the selected Mac.');
  await check('Mac cannot read family', '/v1/family', 403, { token: mac.writeToken });
  await check('Parent cannot publish usage', `/v1/devices/${mac.deviceId}/snapshot`, 403, { method: 'PUT', token: parent.readToken, body: '{}' });
  const differentDevice = mac.deviceId === 'forbidden-probe' ? 'forbidden-probe-2' : 'forbidden-probe';
  await check('Mac cannot publish another device', `/v1/devices/${differentDevice}/snapshot`, 403, { method: 'PUT', token: mac.writeToken, body: '{}' });
  const reporting = family.devices.filter(device => device.snapshot !== null).length;
  report(`Dashboard: ${reporting} of ${family.devices.length} Macs have reported. No accepted snapshot writes were requested.`);
  return { reporting, devices: family.devices.length };
}

async function main() {
  try {
    const args = process.argv.slice(2);
    if (args.length !== 4 || args[0] !== '--parent-file' || args[2] !== '--mac-file') throw new SafeError('Usage: cloud-smoke.mjs --parent-file /private/path/parent-1.json --mac-file /private/path/mac-1.json');
    await runSmoke(loadConnections(args[1], args[3]));
  } catch (error) {
    console.error(error instanceof SafeError ? error.message : 'The connection check failed. No private error details were printed.');
    process.exitCode = 1;
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main();
