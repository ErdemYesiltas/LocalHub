import http from 'node:http';
import { isIP } from 'node:net';
import tls from 'node:tls';
import { normalizeFingerprint } from './invite.ts';

export class PinMismatchError extends Error {
  override name = 'PinMismatchError';
  constructor() {
    super('The hub certificate does not match the paired fingerprint');
  }
}

export interface PinnedRequest {
  method: string;
  path: string;
  headers?: Record<string, string>;
  body?: Buffer | string;
  signal?: AbortSignal;
  timeoutMs?: number;
}

/**
 * Opens a TLS connection and verifies the leaf certificate's SHA-256 against
 * the pin *before* the socket is handed to HTTP, so no header or token can be
 * written to an unverified peer. No CA, hostname or IP is trusted.
 *
 * Electron alternative: `session.setCertificateVerifyProc` only covers
 * Chromium's stack (`net.request`, `session.fetch`). Node `https`/`tls` is used
 * here so the same code runs in plain Node tests and in the main process.
 */
export function connectPinned(address: URL, fingerprint: string, signal?: AbortSignal): Promise<tls.TLSSocket> {
  const expected = normalizeFingerprint(fingerprint);
  const host = address.hostname.replace(/^\[|\]$/g, '');
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason);
    const socket = tls.connect({
      host,
      port: Number(address.port || 443),
      ...(isIP(host) ? {} : { servername: host }),
      // Chain validation is replaced by the pin below; self-signed is expected.
      rejectUnauthorized: false,
      ALPNProtocols: ['http/1.1'],
    });
    const onAbort = () => socket.destroy(signal?.reason as Error);
    signal?.addEventListener('abort', onAbort, { once: true });
    socket.once('error', (error) => {
      signal?.removeEventListener('abort', onAbort);
      reject(error);
    });
    socket.once('secureConnect', () => {
      signal?.removeEventListener('abort', onAbort);
      const certificate = socket.getPeerX509Certificate();
      const now = Date.now();
      if (!certificate || normalizeFingerprint(certificate.fingerprint256) !== expected ||
          Date.parse(certificate.validFrom) > now || Date.parse(certificate.validTo) < now) {
        socket.destroy();
        reject(new PinMismatchError());
        return;
      }
      resolve(socket);
    });
  });
}

/** One request on a freshly pinned connection; the response is a stream. */
export async function pinnedRequest(address: URL, fingerprint: string, options: PinnedRequest): Promise<http.IncomingMessage> {
  const socket = await connectPinned(address, fingerprint, options.signal);
  return new Promise((resolve, reject) => {
    const request = http.request({
      method: options.method,
      path: options.path,
      host: address.host,
      headers: { Host: address.host, Connection: 'close', ...options.headers },
      createConnection: () => socket,
      ...(options.signal ? { signal: options.signal } : {}),
      timeout: options.timeoutMs ?? 120_000,
    });
    request.once('timeout', () => request.destroy(new Error('LocalHub request timed out')));
    request.once('error', reject);
    request.once('response', resolve);
    request.end(options.body);
  });
}

export async function readBody(response: http.IncomingMessage, limit = 16 * 1024 * 1024): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of response) {
    size += (chunk as Buffer).length;
    if (size > limit) {
      response.destroy();
      throw new Error('LocalHub response too large');
    }
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks);
}
