import { fullMatch, MAX_BODY_BYTES } from './validation.mjs';

export class StorageConflict extends Error {}
export class StorageUnavailable extends Error {}

// Google Cloud's attached service identity supplies short-lived access tokens.
// No downloaded service-account key is accepted or required by this service.
export class MetadataCredentials {
  constructor(fetcher = fetch, clock = () => Date.now()) { this.fetcher = fetcher; this.clock = clock; this.cached = null; this.pending = null; }
  async token() {
    if (this.cached && this.cached.expires > this.clock() + 60000) return this.cached.token;
    if (this.pending) return this.pending;
    this.pending = (async () => {
      const response = await this.fetcher('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token', { headers: { 'Metadata-Flavor': 'Google' }, redirect: 'error', signal: AbortSignal.timeout(5000) });
      if (!response.ok || response.headers.get('metadata-flavor') !== 'Google') throw new StorageUnavailable('Service identity is unavailable.');
      const result = await response.json();
      if (typeof result.access_token !== 'string' || !result.access_token || !Number.isFinite(result.expires_in) || result.expires_in <= 60) throw new StorageUnavailable('Service identity is unavailable.');
      this.cached = { token: result.access_token, expires: this.clock() + result.expires_in * 1000 };
      return this.cached.token;
    })();
    try { return await this.pending; } finally { this.pending = null; }
  }
}

export class GCSStorage {
  constructor(bucket, { fetcher = fetch, credentials = new MetadataCredentials(fetcher) } = {}) {
    if (!fullMatch(/^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$/, bucket)) throw new Error('KQ_BUCKET is invalid.');
    this.bucket = bucket; this.fetcher = fetcher; this.credentials = credentials;
  }
  objectURL(deviceId) { return `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(this.bucket)}/o/${encodeURIComponent(`snapshots/${deviceId}.json`)}`; }
  async request(url, options = {}) {
    try {
      return await this.fetcher(url, { ...options, headers: { ...options.headers, Authorization: `Bearer ${await this.credentials.token()}` }, redirect: 'error', signal: AbortSignal.timeout(10000) });
    } catch { throw new StorageUnavailable('Storage is unavailable.'); }
  }
  async read(deviceId) {
    const url = this.objectURL(deviceId);
    const metadata = await this.request(`${url}?fields=generation,size`);
    if (metadata.status === 404) return null;
    if (!metadata.ok) throw new StorageUnavailable('Storage is unavailable.');
    const meta = await metadata.json();
    if (!fullMatch(/^\d+$/, meta.generation) || !fullMatch(/^\d+$/, String(meta.size)) || Number(meta.size) > MAX_BODY_BYTES + 1024) throw new StorageUnavailable('Stored summary is invalid.');
    const response = await this.request(`${url}?alt=media&generation=${meta.generation}`);
    // A concurrent write can retire the generation between metadata and media.
    if (response.status === 404 || response.status === 412) throw new StorageConflict();
    if (!response.ok) throw new StorageUnavailable('Storage is unavailable.');
    let value;
    try { value = await response.json(); } catch { throw new StorageUnavailable('Stored summary is invalid.'); }
    return { generation: meta.generation, value };
  }
  async write(deviceId, value, generation) {
    const name = encodeURIComponent(`snapshots/${deviceId}.json`);
    const url = `https://storage.googleapis.com/upload/storage/v1/b/${encodeURIComponent(this.bucket)}/o?uploadType=media&name=${name}&ifGenerationMatch=${generation ?? '0'}`;
    const response = await this.request(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(value) });
    if (response.status === 412) throw new StorageConflict();
    if (!response.ok) throw new StorageUnavailable('Storage is unavailable.');
    // Drain the successful metadata response to reuse the connection.
    await response.arrayBuffer();
  }
}
