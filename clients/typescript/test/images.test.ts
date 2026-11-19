import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { HubClient, HubRequestError, MemorySessionStore, parseInvite } from '../src/index.ts';
import { json, startFakeHub, type FakeHub } from './helpers.ts';

const TOKEN = 'T'.repeat(44);
const PNG = Buffer.from('89504e470d0a1a0a', 'hex');
let hub: FakeHub;
let lastHeaders: Record<string, string | string[] | undefined> = {};
let lastBody = '';

const job = (status: string) => ({
  id: 'job-1', object: 'job', status, capability: 'image.create', model: 'comfyui/sdxl',
  output_file_ids: status === 'completed' ? ['file-1'] : [], created_at: 1,
});

before(async () => {
  hub = await startFakeHub((request, body, response) => {
    lastHeaders = request.headers;
    lastBody = body;
    switch (`${request.method} ${request.url}`) {
      case 'POST /v2/pair':
        return json(response, 200, { deviceID: 'dev-1', token: TOKEN, scopes: ['chat', 'image.create', 'image.edit'] });
      case 'GET /v2/profiles':
        return json(response, 200, [{ id: 'draft', name: 'Quick Draft', models: {}, steps: 4, width: 512, height: 512 }]);
      case 'POST /v1/images/generations': {
        if (request.headers.prefer === 'respond-async') return json(response, 202, job('queued'));
        const input = JSON.parse(body);
        if (input.model === 'comfyui/missing') {
          return json(response, 404, { error: { code: 'model_not_found', message: 'No create images workflow named comfyui/missing' } });
        }
        return json(response, 200, { created: 1, data: [{ b64_json: PNG.toString('base64'), file_id: 'file-1' }] });
      }
      case 'POST /v1/images/edits':
        return json(response, 200, { created: 1, data: [{ url: 'https://hub/v1/files/file-2/content', file_id: 'file-2' }] });
      case 'POST /v1/files':
        return json(response, 200, { id: 'file-3', object: 'file', bytes: 8, created_at: 1, filename: 'ref.png',
          purpose: 'reference', mime_type: 'image/png', source: 'upload' });
      case 'GET /v1/files':
        return json(response, 200, { object: 'list', data: [] });
      case 'GET /v1/files/file-1/content':
        response.writeHead(200, { 'Content-Type': 'image/png' });
        return response.end(PNG);
      case 'DELETE /v1/files/file-1':
        return json(response, 200, { id: 'file-1', object: 'file', deleted: true });
      case 'POST /v1/jobs/job-1/cancel':
        return json(response, 200, job('cancelled'));
      case 'GET /v1/jobs/job-1/recipe':
        return json(response, 200, { schemaVersion: 1, workflowName: 'SDXL', workflowVersion: 'abc',
          parameters: { prompt: 'a fox', seed: 42 }, inputs: [], modelFiles: ['sdxl.safetensors'] });
      case 'POST /v1/jobs/job-1/replay':
        return json(response, 200, { ...job('queued'), id: JSON.parse(body).variation ? 'job-variation' : 'job-replay', has_recipe: true });
      case 'GET /v1/jobs/job-1/events':
        response.writeHead(200, { 'Content-Type': 'text/event-stream' });
        response.write(`event: progress\ndata: ${JSON.stringify({ ...job('in_progress'), progress: 0.5 })}\n\n`);
        return response.end(`event: completed\ndata: ${JSON.stringify(job('completed'))}\n\n`);
      case 'POST /v1/audio/speech':
        response.writeHead(200, { 'Content-Type': 'audio/flac' });
        return response.end(Buffer.from('fLaC'));
      case 'POST /v1/videos':
        return json(response, 200, { id: 'job-v', object: 'video', status: 'queued', progress: 0, created_at: 1, model: 'comfyui/wan' });
      case 'GET /v1/videos/job-v':
        return json(response, 200, { id: 'job-v', object: 'video', status: 'completed', progress: 100, created_at: 1, model: 'comfyui/wan', file_id: 'file-v' });
      case 'GET /v1/videos/job-v/content':
        response.writeHead(200, { 'Content-Type': 'video/webm' });
        return response.end(Buffer.from('webm'));
      case 'POST /v1/embeddings':
        return json(response, 200, { object: 'list', data: [{ embedding: [0.1, 0.2] }] });
      case 'POST /v1/audio/transcriptions':
        return json(response, 200, { text: 'merhaba dünya' });
      case 'POST /v1/3d/generations':
        return json(response, 200, { created: 1, data: [{ file_id: 'file-3d' }] });
      case 'GET /v1/jobs/job-1/preview':
        response.writeHead(200, { 'Content-Type': 'image/jpeg' });
        return response.end(Buffer.from('jpeg'));
      case 'GET /v1/jobs/job-2/preview':
        return json(response, 404, { error: { code: 'not_found', message: 'No preview' } });
      case 'GET /v2/events':
        response.writeHead(200, { 'Content-Type': 'text/event-stream' });
        response.write(': connected\n\n');
        response.write(`event: job\ndata: ${JSON.stringify({ ...job('in_progress'), queue_position: 0, current_node: 'KSampler 3/20' })}\n\n`);
        response.write('event: session\ndata: {"deviceID":"dev-1","name":"Olive","app":"olive-studio","scopes":["chat"]}\n\n');
        return response.end('event: revoked\ndata: {}\n\n');
      default:
        return json(response, 404, { error: { code: 'not_found', message: 'nope' } });
    }
  });
});

after(() => hub.close());

async function paired(): Promise<HubClient> {
  const client = new HubClient(new MemorySessionStore());
  await client.pair(parseInvite(`localhub://pair?v=2&u=${encodeURIComponent(hub.url.origin)}&fp=${hub.fingerprint}&c=123456`),
    { deviceName: 'Olive', app: 'olive-studio' });
  return client;
}

test('reads a production recipe and replays the original or a variation', async () => {
  const client = await paired();
  const recipe = await client.recipe('job-1');
  assert.equal(recipe.parameters.seed, 42);
  assert.equal(recipe.workflowName, 'SDXL');
  assert.equal((await client.replayJob('job-1')).id, 'job-replay');
  assert.equal((await client.replayJob('job-1', true)).id, 'job-variation');
});

test('discovers work profiles and sends profile choices including explicit defaults', async () => {
  const client = await paired();
  const profiles = await client.workProfiles();
  assert.equal(profiles.length, 1);
  assert.equal(profiles[0]?.steps, 4);
  await client.generateImage({ prompt: 'a fox', profile: 'draft' });
  assert.equal(JSON.parse(lastBody).profile, 'draft');
  await client.transcribe(PNG, 'audio.wav', { profile: '' });
  assert.match(lastBody, /name="profile"/);
});

test('generates an image synchronously and asynchronously', async () => {
  const client = await paired();
  const result = await client.generateImage({ prompt: 'a paper boat', size: '512x512', seed: 7 });
  assert.deepEqual(Buffer.from(result.data[0]!.b64_json!, 'base64'), PNG);
  assert.deepEqual(JSON.parse(hub.requests.at(-1)!.body), { prompt: 'a paper boat', size: '512x512', seed: 7 });

  const queued = await client.generateImage({ prompt: 'later' }, { async: true });
  assert.equal(queued.status, 'queued');
  assert.equal(lastHeaders.prefer, 'respond-async');

  await assert.rejects(client.generateImage({ prompt: 'x', model: 'comfyui/missing' }),
    (error: unknown) => error instanceof HubRequestError && error.code === 'model_not_found' && error.status === 404);
});

test('edits send the image and fields as multipart', async () => {
  const client = await paired();
  const result = await client.editImage({ prompt: 'add a hat', image: { data: PNG, filename: 'photo.png' }, response_format: 'url', strength: 0.6 });
  assert.equal(result.data[0]!.file_id, 'file-2');
  assert.match(String(lastHeaders['content-type']), /^multipart\/form-data; boundary=localhub-/);
  const body = hub.requests.at(-1)!.body;
  assert.match(body, /name="prompt"\r\n\r\nadd a hat\r\n/);
  assert.match(body, /name="strength"\r\n\r\n0.6\r\n/);
  assert.match(body, /name="image"; filename="photo.png"\r\nContent-Type: image\/png/);
});

test('uploads, reads and deletes files', async () => {
  const client = await paired();
  const file = await client.uploadFile(PNG, 'ref.png', { purpose: 'reference', contentType: 'image/png' });
  assert.equal(file.id, 'file-3');
  assert.match(hub.requests.at(-1)!.body, /name="purpose"\r\n\r\nreference/);
  assert.deepEqual(await client.files(), []);
  assert.deepEqual(await client.fileContent('file-1'), PNG);
  await client.deleteFile('file-1');
  assert.equal(hub.requests.at(-1)!.method, 'DELETE');
});

test('follows and cancels jobs', async () => {
  const client = await paired();
  const states: string[] = [];
  for await (const update of client.jobEvents('job-1')) states.push(`${update.status}:${update.progress ?? ''}`);
  assert.deepEqual(states, ['in_progress:0.5', 'completed:']);
  assert.equal((await client.cancelJob('job-1')).status, 'cancelled');
});

test('speaks text and creates videos the OpenAI way', async () => {
  const client = await paired();
  const speech = await client.speech({ input: 'Merhaba', voice: 'alloy' });
  assert.equal(speech.contentType, 'audio/flac');
  assert.equal(speech.data.toString(), 'fLaC');
  assert.deepEqual(JSON.parse(hub.requests.at(-1)!.body), { input: 'Merhaba', voice: 'alloy' });

  const queued = await client.createVideo({ prompt: 'a paper boat', seconds: '4', size: '832x480' });
  assert.equal(queued.status, 'queued');
  assert.equal((await client.video(queued.id)).status, 'completed');
  assert.equal((await client.videoContent(queued.id)).toString(), 'webm');
});

test('embeddings, transcription, 3D, previews and the device event stream', async () => {
  const client = await paired();
  assert.deepEqual(await client.embeddings('lmstudio/nomic', 'a fox'), [[0.1, 0.2]]);
  assert.equal(await client.transcribe(Buffer.from('RIFF'), 'note.wav', { language: 'tr' }), 'merhaba dünya');
  assert.match(hub.requests.at(-1)!.body, /name="language"\r\n\r\ntr/);
  const mesh = await client.generate3D({ image: { data: PNG, filename: 'chair.png' } });
  assert.equal((mesh as { data: { file_id: string }[] }).data[0]!.file_id, 'file-3d');
  assert.equal((await client.jobPreview('job-1'))?.toString(), 'jpeg');
  assert.equal(await client.jobPreview('job-2'), null);

  const seen: string[] = [];
  for await (const event of client.events()) {
    seen.push(event.type === 'job' ? `job:${event.job.current_node}` : event.type === 'session' ? `session:${event.scopes.join()}` : event.type);
  }
  assert.deepEqual(seen, ['job:KSampler 3/20', 'session:chat', 'revoked']);
});
