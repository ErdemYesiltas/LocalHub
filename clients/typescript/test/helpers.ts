import { execFileSync } from 'node:child_process';
import { X509Certificate } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';
import https from 'node:https';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export interface FakeHub {
  url: URL;
  fingerprint: string;
  requests: { method: string; path: string; authorization?: string; body: string }[];
  close(): Promise<void>;
}

export type Handler = (request: IncomingMessage, body: string, response: ServerResponse) => void;

let cached: { key: Buffer; cert: Buffer; fingerprint: string } | undefined;

/** Self-signed RSA cert like the hub's, made once per test process. */
export function certificate() {
  if (cached) return cached;
  const dir = mkdtempSync(join(tmpdir(), 'localhub-ts-'));
  execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
    '-subj', '/CN=LocalHub', '-keyout', join(dir, 'key.pem'), '-out', join(dir, 'cert.pem')], { stdio: 'ignore' });
  const cert = readFileSync(join(dir, 'cert.pem'));
  const key = readFileSync(join(dir, 'key.pem'));
  rmSync(dir, { recursive: true, force: true });
  cached = { key, cert, fingerprint: new X509Certificate(cert).fingerprint256.replace(/:/g, '').toLowerCase() };
  return cached;
}

export async function startFakeHub(handler: Handler): Promise<FakeHub> {
  const { key, cert, fingerprint } = certificate();
  const requests: FakeHub['requests'] = [];
  const server = https.createServer({ key, cert }, (request, response) => {
    let body = '';
    request.setEncoding('utf8');
    request.on('data', (chunk: string) => (body += chunk));
    request.on('end', () => {
      requests.push({
        method: request.method!, path: request.url!, body,
        ...(request.headers.authorization ? { authorization: request.headers.authorization } : {}),
      });
      handler(request, body, response);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;
  return {
    url: new URL(`https://127.0.0.1:${port}`),
    fingerprint,
    requests,
    close: () => new Promise((resolve) => {
      server.closeAllConnections();
      server.close(() => resolve());
    }),
  };
}

export function json(response: ServerResponse, status: number, value: unknown) {
  response.writeHead(status, { 'Content-Type': 'application/json' });
  response.end(JSON.stringify(value));
}
