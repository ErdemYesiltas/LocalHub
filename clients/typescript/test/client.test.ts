import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import {
  HubClient, HubRequestError, MemorySessionStore, PinMismatchError, SafeStorageSessionStore,
  parseInvite, pinnedRequest, type HubInvite,
} from '../src/index.ts';
import { json, startFakeHub, type FakeHub } from './helpers.ts';

const TOKEN = 'T'.repeat(44);
let hub: FakeHub;

before(async () => {
  hub = await startFakeHub((request, body, response) => {
    const authed = request.headers.authorization === `Bearer ${TOKEN}`;
    switch (`${request.method} ${request.url}`) {
      case 'POST /v2/pair': {
        const input = JSON.parse(body);
        if (input.code !== '123456') return json(response, 401, { error: { code: 'wrong_code', message: 'Wrong pairing code' } });
        return json(response, 200, { deviceID: 'dev-1', token: TOKEN, scopes: ['lmstudio'] });
      }
      case 'GET /v1/models':
        if (!authed) return json(response, 401, { error: { code: 'unauthorized', message: 'Pair first' } });
        return json(response, 200, { object: 'list', data: [{ id: 'lmstudio/qwen/qwen3-8b', object: 'model', owned_by: 'lmstudio', provider: 'lmstudio', upstream_id: 'qwen/qwen3-8b' }] });
      case 'POST /v1/chat/completions': {
        const input = JSON.parse(body);
        if (input.model.startsWith('ollama/')) {
          return json(response, 503, { error: { code: 'provider_unavailable', message: 'Ollama is not running on this Mac', provider: 'ollama' } });
        }
        response.writeHead(200, { 'Content-Type': 'text/event-stream' });
        response.write('data: {"choices":[{"delta":{"content":"Mer"}}]}\n\n');
        response.write('data: {"choices":[{"delta":{"content":"haba"}}]}\n\n');
        return response.end('data: [DONE]\n\n');
      }
      case 'DELETE /v2/session':
        response.writeHead(204);
        return response.end();
      default:
        return json(response, 404, { error: { code: 'not_found', message: 'nope' } });
    }
  });
});

after(() => hub.close());

function invite(fingerprint = hub.fingerprint, code = '123456'): HubInvite {
  return parseInvite(`localhub://pair?v=2&u=${encodeURIComponent(hub.url.origin)}&fp=${fingerprint}&c=${code}&id=hub-1`);
}

test('pairs from a QR invite, stores the session and lists models over the pin', async () => {
  const store = new MemorySessionStore();
  const client = new HubClient(store);
  const session = await client.pair(invite(), { deviceName: 'Olive on MacBook', app: 'olive-studio' });
  assert.equal(session.token, TOKEN);
  assert.deepEqual(session.scopes, ['lmstudio']);
  assert.equal(session.hubID, 'hub-1');
  assert.deepEqual(await store.load(), session);
  const pairBody = JSON.parse(hub.requests.at(-1)!.body);
  assert.deepEqual(pairBody, { code: '123456', deviceName: 'Olive on MacBook', app: 'olive-studio' });

  const models = await client.models();
  assert.deepEqual(models.map((m) => m.id), ['lmstudio/qwen/qwen3-8b']);
  assert.equal(hub.requests.at(-1)!.authorization, `Bearer ${TOKEN}`);

  const restored = new HubClient(store);
  await restored.restore();
  assert.equal((await restored.models()).length, 1);
});

test('a wrong pin fails before any byte of HTTP reaches the server', async () => {
  const before = hub.requests.length;
  const client = new HubClient(new MemorySessionStore());
  await assert.rejects(client.pair(invite('00'.repeat(32)), { deviceName: 'x', app: 'olive-studio' }), PinMismatchError);
  await assert.rejects(pinnedRequest(hub.url, 'ff'.repeat(32), {
    method: 'GET', path: '/v1/models', headers: { Authorization: `Bearer ${TOKEN}` },
  }), PinMismatchError);
  assert.equal(hub.requests.length, before, 'no request, so no token, was sent');
});

test('hub errors surface with their code, and a wrong code never stores a session', async () => {
  const store = new MemorySessionStore();
  const client = new HubClient(store);
  await assert.rejects(client.pair(invite(hub.fingerprint, '000000'), { deviceName: 'x', app: 'olive-studio' }),
    (error: unknown) => error instanceof HubRequestError && error.code === 'wrong_code' && error.status === 401);
  assert.equal(await store.load(), null);

  await client.pair(invite(), { deviceName: 'x', app: 'olive-studio' });
  await assert.rejects(client.chat({ model: 'ollama/llama3', messages: [] }), (error: unknown) =>
    error instanceof HubRequestError && error.status === 503 && error.code === 'provider_unavailable' &&
    error.provider === 'ollama');
});

test('streams chat chunks and unpairs', async () => {
  const store = new MemorySessionStore();
  const client = new HubClient(store);
  await client.pair(invite(), { deviceName: 'x', app: 'olive-studio' });
  const text: string[] = [];
  for await (const chunk of client.chatStream({ model: 'lmstudio/qwen/qwen3-8b', messages: [] })) {
    text.push((chunk as { choices: { delta: { content: string } }[] }).choices[0]!.delta.content);
  }
  assert.equal(text.join(''), 'Merhaba');
  assert.equal(JSON.parse(hub.requests.at(-1)!.body).stream, true);

  await client.unpair();
  assert.equal(hub.requests.at(-1)!.method, 'DELETE');
  assert.equal(await store.load(), null);
  await assert.rejects(client.models(), /not paired/);
});

test('rejects paths that would leave the paired hub', async () => {
  const client = new HubClient(new MemorySessionStore());
  await client.pair(invite(), { deviceName: 'x', app: 'olive-studio' });
  await assert.rejects(client.request('GET', '//evil.example/v1/models'), /relative to the paired hub/);
  await assert.rejects(client.request('GET', 'https://evil.example/v1/models'), /relative to the paired hub/);
});

test('safeStorage session store never writes the token in plain text', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'localhub-store-'));
  try {
    const fake = {
      isEncryptionAvailable: () => true,
      encryptString: (plain: string) => Buffer.from(plain, 'utf8').map((b) => b ^ 0x5a) as Buffer,
      decryptString: (data: Buffer) => Buffer.from(data.map((b) => b ^ 0x5a)).toString('utf8'),
    };
    const store = new SafeStorageSessionStore(fake, join(dir, 'nested', 'localhub-session.bin'));
    const client = new HubClient(store);
    const session = await client.pair(invite(), { deviceName: 'x', app: 'olive-studio' });
    const raw = readFileSync(store.path);
    assert.equal(raw.includes(Buffer.from(TOKEN)), false);
    assert.equal(statSync(store.path).mode & 0o777, 0o600);
    assert.deepEqual(await new SafeStorageSessionStore(fake, store.path).load(), session);

    const unavailable = new SafeStorageSessionStore({ ...fake, isEncryptionAvailable: () => false }, join(dir, 'x.bin'));
    await assert.rejects(unavailable.save(session), /Secure storage is not available/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
