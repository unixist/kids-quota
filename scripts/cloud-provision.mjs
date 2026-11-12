#!/usr/bin/env node
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fullMatch, tokenDigest, validEndpoint, validID, validText, validateConfig } from '../cloud/src/validation.mjs';

// Pairing documents contain credentials. All files are created exclusively and
// owner-only; only digests are used by the deployed service. Nothing secret is
// printed. The output must live outside this checkout.
const root = realpathSync(resolve(dirname(fileURLToPath(import.meta.url)), '..'));
const usage = 'Usage: cloud-provision.mjs --out /private/path [--family "Our family"] [--device "Kids Mac"] [--device "Second Mac"] [--reader "Parent 1"] [--reader "Parent 2"] [--endpoint https://relay.run.app]\n       cloud-provision.mjs --out /same/private/path --set-endpoint https://relay.run.app';
class SafeError extends Error {}
function fail() { throw new SafeError(usage); }
const args = process.argv.slice(2), settings = { devices: [], readers: [] };
try {
for (let i = 0; i < args.length; i += 2) {
  const key = args[i], value = args[i + 1];
  if (!value || !['--out', '--family', '--device', '--reader', '--endpoint', '--set-endpoint'].includes(key)) fail();
  if (key === '--device') settings.devices.push(value);
  else if (key === '--reader') settings.readers.push(value);
  else { if (Object.hasOwn(settings, key)) fail(); settings[key] = value; }
}
  if (!settings['--out'] || !isAbsolute(settings['--out'])) fail();
  const requestedOutput = resolve(settings['--out']);
  const outputParent = realpathSync(dirname(requestedOutput));
  const output = resolve(outputParent, requestedOutput.split(sep).at(-1));
  const relation = relative(root, output);
  if (!relation || (!relation.startsWith(`..${sep}`) && relation !== '..' && !isAbsolute(relation))) throw new SafeError('Pairing files must be outside the repository.');
  const endpoint = settings['--set-endpoint'] ?? settings['--endpoint'];
  if (endpoint && !validEndpoint(endpoint)) throw new SafeError('The endpoint must be an HTTPS origin.');
  const origin = endpoint ? new URL(endpoint).origin : null;
  if (settings['--set-endpoint']) {
    if (settings.devices.length || settings.readers.length || settings['--family'] || settings['--endpoint']) fail();
    if (realpathSync(output) !== output || (statSync(output).mode & 0o077) !== 0) throw new SafeError('The private output directory must be owner-only and not a symlink.');
    const manifest = JSON.parse(readFileSync(resolve(output, 'pairing-manifest.json'), 'utf8'));
    if (!Array.isArray(manifest.files) || manifest.files.some(name => !fullMatch(/^(?:mac|parent)-\d+\.json$/, name))) throw new SafeError('Invalid pairing manifest.');
    for (const name of manifest.files) {
      const file = resolve(output, name);
      if (realpathSync(file) !== file || (statSync(file).mode & 0o077) !== 0) throw new SafeError('Pairing files must be owner-only and not symlinks.');
      const document = JSON.parse(readFileSync(file, 'utf8'));
      document.endpoint = origin;
      const temporary = `${file}.${randomBytes(6).toString('hex')}.tmp`;
      writeFileSync(temporary, JSON.stringify(document, null, 2) + '\n', { mode: 0o600, flag: 'wx' }); renameSync(temporary, file);
    }
    console.log(`Connection endpoint saved in ${manifest.files.length} private pairing files.`);
    process.exit(0);
  }
  if (existsSync(output)) throw new SafeError('Output directory already exists; use a new private directory or --set-endpoint.');
  const familyName = settings['--family'] ?? 'Our family';
  const devices = settings.devices.length ? settings.devices : ['Kids Mac 1', 'Kids Mac 2'];
  const readers = settings.readers.length ? settings.readers : ['Parent 1', 'Parent 2'];
  if (!validText(familyName) || devices.length > 20 || readers.length > 20 || [...devices, ...readers].some(name => !validText(name))) throw new SafeError('Use 1–20 device/parent names, each at most 100 characters.');
  mkdirSync(output, { mode: 0o700 });
  const config = { familyName, readers: [], devices: [] }, files = [];
  const save = (name, data) => writeFileSync(resolve(output, name), JSON.stringify(data, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  for (const [index, deviceName] of devices.entries()) {
    const deviceId = `mac-${index + 1}`, writeToken = randomBytes(32).toString('base64url');
    if (!validID(deviceId)) fail();
    config.devices.push({ deviceId, deviceName, tokenSha256: tokenDigest(writeToken) });
    const name = `${deviceId}.json`; files.push(name);
    save(name, { schemaVersion: 1, endpoint: origin ?? 'https://SET-AFTER-DEPLOYMENT.invalid', deviceId, deviceName, writeToken });
  }
  for (const [index, name] of readers.entries()) {
    const id = `parent-${index + 1}`, readToken = randomBytes(32).toString('base64url');
    config.readers.push({ id, name, tokenSha256: tokenDigest(readToken) });
    const file = `${id}.json`; files.push(file);
    save(file, { schemaVersion: 1, endpoint: origin ?? 'https://SET-AFTER-DEPLOYMENT.invalid', familyName, readToken });
  }
  save('auth-config.json', validateConfig(config));
  save('pairing-manifest.json', { schemaVersion: 1, files });
  console.log(`Prepared ${devices.length} Mac connections and ${readers.length} parent connections in the private output directory. Credentials were not printed.`);
  if (!origin) console.log('After deploying, run --set-endpoint with the relay HTTPS origin before pairing any device.');
} catch (error) {
  // JSON.parse errors in recent Node releases can quote the private input.
  // Only messages authored above are safe to display.
  console.error(error instanceof SafeError ? error.message : 'Unable to read or update the private pairing files. Check their JSON and permissions.');
  process.exit(1);
}
