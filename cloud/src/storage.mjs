import { fullMatch, MAX_BODY_BYTES } from './validation.mjs';
import { withAbort } from './cancellation.mjs';

export class StorageConflict extends Error {}
const categories = new Set(['identity_unavailable', 'storage_unavailable', 'storage_read_failed', 'storage_write_failed', 'stored_snapshot_invalid', 'storage_contention', 'family_too_large']);
export class StorageUnavailable extends Error {
  constructor(category = 'storage_unavailable') {
    super('Quota storage is unavailable.');
    this.category = categories.has(category) ? category : 'storage_unavailable';
  }
}
const boundedSignal = (signal, milliseconds) => signal ? AbortSignal.any([signal, AbortSignal.timeout(milliseconds)]) : AbortSignal.timeout(milliseconds);

// Google Cloud's attached service identity supplies short-lived access tokens.
// No downloaded service-account key is accepted or required by this service.
export class MetadataCredentials {
  constructor(fetcher = fetch, clock = () => Date.now()) { this.fetcher = fetcher; this.clock = clock; this.cached = null; this.pending = new Map(); }
  async token(signal) {
    signal?.throwIfAborted();
    if (this.cached && this.cached.expires > this.clock() + 60000) return this.cached.token;
    // Coalesce within one request. A disconnected request must not cancel the
    // identity refresh belonging to another phone or Mac.
    if (this.pending.has(signal)) return this.pending.get(signal);
    const work = (async () => {
      const bounded = boundedSignal(signal, 5000);
      try {
        const response = await withAbort(this.fetcher('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token', { headers: { 'Metadata-Flavor': 'Google' }, redirect: 'error', signal: bounded }), bounded);
        if (!response.ok || response.headers.get('metadata-flavor') !== 'Google') throw new StorageUnavailable('identity_unavailable');
        const result = await withAbort(response.json(), bounded);
        bounded.throwIfAborted();
        if (typeof result.access_token !== 'string' || !result.access_token || !Number.isFinite(result.expires_in) || result.expires_in <= 60) throw new StorageUnavailable('identity_unavailable');
        this.cached = { token: result.access_token, expires: this.clock() + result.expires_in * 1000 };
        return this.cached.token;
      } catch {
        signal?.throwIfAborted();
        throw new StorageUnavailable('identity_unavailable');
      }
    })();
    this.pending.set(signal, work);
    try { return await work; } finally { this.pending.delete(signal); }
  }
}

export class GCSStorage {
  constructor(bucket, { fetcher = fetch, credentials = new MetadataCredentials(fetcher) } = {}) {
    if (!fullMatch(/^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$/, bucket)) throw new Error('KQ_BUCKET is invalid.');
    this.bucket = bucket; this.fetcher = fetcher; this.credentials = credentials;
  }
  objectURL(deviceId) { return `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(this.bucket)}/o/${encodeURIComponent(`snapshots/${deviceId}.json`)}`; }
  async request(url, options, signal, category) {
    try {
      signal.throwIfAborted();
      const token = await this.credentials.token(signal);
      signal.throwIfAborted();
      return await withAbort(this.fetcher(url, { ...options, headers: { ...options?.headers, Authorization: `Bearer ${token}` }, redirect: 'error', signal }), signal);
    } catch (error) {
      signal.throwIfAborted();
      if (error instanceof StorageUnavailable) throw error;
      throw new StorageUnavailable(category);
    }
  }
  async read(deviceId, signal) {
    const bounded = signal ?? AbortSignal.timeout(10000), url = this.objectURL(deviceId);
    try {
      const metadata = await this.request(`${url}?fields=generation,size`, undefined, bounded, 'storage_read_failed');
      if (metadata.status === 404) return null;
      if (!metadata.ok) throw new StorageUnavailable('storage_read_failed');
      const meta = await withAbort(metadata.json(), bounded);
      if (!fullMatch(/^\d+$/, meta.generation) || !fullMatch(/^\d+$/, String(meta.size)) || Number(meta.size) > MAX_BODY_BYTES + 1024) throw new StorageUnavailable('stored_snapshot_invalid');
      const response = await this.request(`${url}?alt=media&generation=${meta.generation}`, undefined, bounded, 'storage_read_failed');
      // A concurrent write can retire the generation between metadata and media.
      if (response.status === 404 || response.status === 412) throw new StorageConflict();
      if (!response.ok) throw new StorageUnavailable('storage_read_failed');
      const value = await withAbort(response.json(), bounded);
      bounded.throwIfAborted();
      return { generation: meta.generation, value };
    } catch (error) {
      signal?.throwIfAborted();
      if (error instanceof StorageConflict || error instanceof StorageUnavailable) throw error;
      throw new StorageUnavailable(error instanceof SyntaxError ? 'stored_snapshot_invalid' : 'storage_read_failed');
    }
  }
  async write(deviceId, value, generation, signal) {
    const bounded = signal ?? AbortSignal.timeout(10000), name = encodeURIComponent(`snapshots/${deviceId}.json`);
    const url = `https://storage.googleapis.com/upload/storage/v1/b/${encodeURIComponent(this.bucket)}/o?uploadType=media&name=${name}&ifGenerationMatch=${generation ?? '0'}`;
    try {
      const response = await this.request(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(value) }, bounded, 'storage_write_failed');
      if (response.status === 412) throw new StorageConflict();
      if (!response.ok) throw new StorageUnavailable('storage_write_failed');
      // Drain the successful metadata response to reuse the connection.
      await withAbort(response.arrayBuffer(), bounded);
    } catch (error) {
      signal?.throwIfAborted();
      if (error instanceof StorageConflict || error instanceof StorageUnavailable) throw error;
      throw new StorageUnavailable('storage_write_failed');
    }
  }
}
