// Stop waiting promptly even if an adapter has not yet rejected its operation.
// Real network operations also receive this signal so the work itself is canceled.
export function withAbort(operation, signal) {
  if (!signal) return operation;
  return new Promise((resolve, reject) => {
    const aborted = () => { signal.removeEventListener('abort', aborted); reject(signal.reason); };
    signal.addEventListener('abort', aborted, { once: true });
    if (signal.aborted) aborted();
    Promise.resolve(operation).then(resolve, reject).finally(() => signal.removeEventListener('abort', aborted));
  });
}
