import http from 'node:http';
import { createRelay } from './relay.mjs';
import { GCSStorage } from './storage.mjs';

try {
  const config = JSON.parse(process.env.KQ_AUTH_CONFIG ?? 'null');
  const storage = new GCSStorage(process.env.KQ_BUCKET);
  const port = Number(process.env.PORT ?? '8080');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT is invalid.');
  const server = http.createServer({ requestTimeout: 20000, headersTimeout: 10000, maxHeaderSize: 8192 }, createRelay({ config, storage }));
  server.keepAliveTimeout = 5000;
  server.maxRequestsPerSocket = 100;
  server.on('clientError', (_error, socket) => { socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); });
  const stop = () => { server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 8000).unref(); };
  process.on('SIGTERM', stop); process.on('SIGINT', stop);
  server.listen(port, '0.0.0.0', () => console.log('Kids Quota read-only phone relay is ready.'));
} catch {
  console.error('Kids Quota relay could not start. Check its private runtime configuration.');
  process.exit(1);
}
