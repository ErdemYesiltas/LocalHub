import { randomUUID } from 'node:crypto';
import type { IncomingMessage } from 'node:http';
import { hubAddress, normalizeFingerprint, type HubInvite } from './invite.ts';
import { discoverHubs } from './discovery.ts';
import { pinnedRequest, readBody } from './pinned.ts';
import type { SessionStore } from './session-store.ts';

export interface HubSession {
  address: string;
  fingerprint: string;
  token: string;
  deviceID: string;
  scopes: string[];
  hubID?: string;
  hubName?: string;
}

export interface HubModel {
  id: string;
  object: 'model';
  owned_by: string;
  provider: string;
  upstream_id: string;
  /** e.g. `["chat"]`, or `["image.edit"]` for a ComfyUI workflow. */
  capabilities: string[];
}

export interface IntegrationStatus {
  id: string;
  name: string;
  kind: string;
  state: 'running' | 'unreachable' | 'error';
  capabilities: string[];
  models?: number;
  detail?: string;
}

/** The hub's `{"error": {code, message, provider?}}`, e.g. `provider_unavailable` when LM Studio is closed. */
export class HubRequestError extends Error {
  override name = 'HubRequestError';
  readonly status: number;
  readonly code: string;
  readonly provider: string | undefined;
  constructor(status: number, code: string, message: string, provider?: string) {
    super(message);
    this.status = status;
    this.code = code;
    this.provider = provider;
  }
}

export interface PairOptions {
  deviceName: string;
  /** Client app id, e.g. `olive-studio`. */
  app: string;
  /** Narrow what the device asks for; the hub grants at most its default scopes. */
  scopes?: string[];
  signal?: AbortSignal;
}

export function validateSession(value: unknown): HubSession {
  const s = value as Partial<HubSession> | null;
  if (!s || typeof s.token !== 'string' || s.token.length < 32 || s.token.length > 200 ||
      typeof s.deviceID !== 'string' || !s.deviceID || typeof s.address !== 'string' ||
      typeof s.fingerprint !== 'string' || !Array.isArray(s.scopes)) {
    throw new Error('Invalid LocalHub session');
  }
  return {
    ...s,
    address: hubAddress(s.address).origin,
    fingerprint: normalizeFingerprint(s.fingerprint),
  } as HubSession;
}

/**
 * Lives in the Electron main process (or any Node process). The renderer only
 * ever sees invite text going in and results coming out — never the token.
 */
export class HubClient {
  readonly store: SessionStore;
  #session: HubSession | null = null;

  constructor(store: SessionStore) {
    this.store = store;
  }

  get session(): HubSession | null {
    return this.#session;
  }

  async restore(): Promise<HubSession | null> {
    const saved = await this.store.load();
    this.#session = saved ? validateSession(saved) : null;
    return this.#session;
  }

  async pair(invite: HubInvite, options: PairOptions): Promise<HubSession> {
    const body: Record<string, unknown> = { code: invite.code, deviceName: options.deviceName.trim(), app: options.app };
    if (options.scopes) body.scopes = options.scopes;
    const path = invite.version === 2 ? '/v2/pair' : '/pair';
    const result = await this.#json(invite.address, invite.fingerprint, null, 'POST', path, { json: body, signal: options.signal }) as
      { deviceID: string; token: string; scopes?: string[] };
    const session = validateSession({
      address: invite.address.origin,
      fingerprint: invite.fingerprint,
      token: result.token,
      deviceID: result.deviceID,
      scopes: result.scopes ?? [],
      ...(invite.hubID ? { hubID: invite.hubID } : {}),
      ...(invite.hubName ? { hubName: invite.hubName } : {}),
    });
    await this.store.save(session);
    this.#session = session;
    return session;
  }

  async unpair(): Promise<void> {
    if (this.#session) {
      try {
        await this.request('DELETE', '/v2/session');
      } catch (error) {
        if (!(error instanceof HubRequestError && error.status === 401)) throw error;
      }
    }
    await this.store.clear();
    this.#session = null;
  }

  async models(signal?: AbortSignal): Promise<HubModel[]> {
    return ((await this.request('GET', '/v1/models', undefined, signal)) as { data: HubModel[] }).data;
  }

  /** Each integration (LM Studio, ComfyUI…) this device may use, and whether it is running. */
  async workProfiles(signal?: AbortSignal): Promise<WorkProfile[]> {
    return this.#call('GET', '/v2/profiles', { signal }) as Promise<WorkProfile[]>;
  }

  async integrations(signal?: AbortSignal): Promise<IntegrationStatus[]> {
    return (await this.request('GET', '/v2/integrations', undefined, signal)) as IntegrationStatus[];
  }

  async chat(body: Record<string, unknown>, signal?: AbortSignal): Promise<unknown> {
    return this.request('POST', '/v1/chat/completions', { ...body, stream: false }, signal);
  }

  /**
   * Yields OpenAI `chat.completion.chunk` objects. Aborting the signal closes
   * the connection; the hub then cancels the upstream generation.
   */
  async *chatStream(body: Record<string, unknown>, signal?: AbortSignal): AsyncGenerator<unknown> {
    const response = await this.#send('POST', '/v1/chat/completions', { ...body, stream: true }, signal,
      { Accept: 'text/event-stream' }, IMAGE_TIMEOUT);
    if (response.statusCode !== 200) throw await toError(response);
    for await (const data of sseData(response)) {
      if (data === '[DONE]') return;
      yield JSON.parse(data);
    }
  }

  // MARK: Images (OpenAI `/v1/images/*`). Local workflows can take minutes; the
  // default wait is 11 minutes. Pass `async: true` to get a job back immediately.

  generateImage(body: ImageGenerateRequest, options: ImageOptions & { async: true }): Promise<HubJob>;
  generateImage(body: ImageGenerateRequest, options?: ImageOptions): Promise<ImagesResponse>;
  async generateImage(body: ImageGenerateRequest, options: ImageOptions = {}): Promise<ImagesResponse | HubJob> {
    return this.#call('POST', '/v1/images/generations', {
      json: body, signal: options.signal, timeoutMs: IMAGE_TIMEOUT,
      headers: options.async ? { Prefer: 'respond-async' } : {},
    }) as Promise<ImagesResponse | HubJob>;
  }

  editImage(body: ImageEditRequest, options: ImageOptions & { async: true }): Promise<HubJob>;
  editImage(body: ImageEditRequest, options?: ImageOptions): Promise<ImagesResponse>;
  async editImage(body: ImageEditRequest, options: ImageOptions = {}): Promise<ImagesResponse | HubJob> {
    const { image, mask, ...fields } = body;
    const parts: MultipartPart[] = [];
    for (const [name, value] of Object.entries(fields)) {
      if (value !== undefined) parts.push({ name, value: String(value) });
    }
    if (image) parts.push({ name: 'image', value: image.data, filename: image.filename ?? 'image.png', contentType: 'image/png' });
    if (mask) parts.push({ name: 'mask', value: mask.data, filename: mask.filename ?? 'mask.png', contentType: 'image/png' });
    return this.#call('POST', '/v1/images/edits', {
      multipart: parts, signal: options.signal, timeoutMs: IMAGE_TIMEOUT,
      headers: options.async ? { Prefer: 'respond-async' } : {},
    }) as Promise<ImagesResponse | HubJob>;
  }

  // MARK: Audio and video

  generateAudio(body: AudioGenerateRequest, options: ImageOptions & { async: true }): Promise<HubJob>;
  generateAudio(body: AudioGenerateRequest, options?: ImageOptions): Promise<ImagesResponse>;
  async generateAudio(body: AudioGenerateRequest, options: ImageOptions = {}): Promise<ImagesResponse | HubJob> {
    return this.#call('POST', '/v1/audio/generations', {
      json: body, signal: options.signal, timeoutMs: IMAGE_TIMEOUT,
      headers: options.async ? { Prefer: 'respond-async' } : {},
    }) as Promise<ImagesResponse | HubJob>;
  }

  /** OpenAI `/v1/audio/speech`: the audio bytes, in whatever format the Mac's workflow saves. */
  async speech(body: { input: string; model?: string; voice?: string; profile?: string }, signal?: AbortSignal): Promise<{ data: Buffer; contentType: string }> {
    const response = await this.#send('POST', '/v1/audio/speech', body, signal, { Accept: '*/*' }, IMAGE_TIMEOUT);
    if (response.statusCode !== 200) throw await toError(response);
    return { data: await readBody(response, 256 * 1024 * 1024), contentType: String(response.headers['content-type'] ?? '') };
  }

  /** OpenAI `/v1/videos`: always asynchronous; poll `video()` or follow `jobEvents()`. */
  async createVideo(body: VideoCreateRequest, signal?: AbortSignal): Promise<HubVideo> {
    return this.#call('POST', '/v1/videos', { json: body, signal }) as Promise<HubVideo>;
  }

  async video(id: string, signal?: AbortSignal): Promise<HubVideo> {
    return this.#call('GET', `/v1/videos/${encodeURIComponent(id)}`, { signal }) as Promise<HubVideo>;
  }

  async videoContent(id: string, signal?: AbortSignal): Promise<Buffer> {
    const response = await this.#send('GET', `/v1/videos/${encodeURIComponent(id)}/content`, undefined, signal);
    if (response.statusCode !== 200) throw await toError(response);
    return readBody(response, 1024 * 1024 * 1024);
  }

  async remixVideo(id: string, body: { prompt: string; model?: string }, signal?: AbortSignal): Promise<HubVideo> {
    return this.#call('POST', `/v1/videos/${encodeURIComponent(id)}/remix`, { json: body, signal }) as Promise<HubVideo>;
  }

  async deleteVideo(id: string, signal?: AbortSignal): Promise<void> {
    await this.#call('DELETE', `/v1/videos/${encodeURIComponent(id)}`, { signal });
  }

  async embeddings(model: string, input: string | string[], signal?: AbortSignal, profile?: string): Promise<number[][]> {
    const reply = await this.#call('POST', '/v1/embeddings', { json: { model, input, profile }, signal }) as { data: { embedding: number[] }[] };
    return reply.data.map((item) => item.embedding);
  }

  /** whisper.cpp or an OpenAI-style transcription server on the Mac. `model` may be `<integration>/<model>`. */
  async transcribe(audio: Buffer, filename: string, options: { model?: string; language?: string; prompt?: string; profile?: string; signal?: AbortSignal } = {}): Promise<string> {
    const parts: MultipartPart[] = [{ name: 'file', value: audio, filename, contentType: 'application/octet-stream' }];
    for (const key of ['model', 'language', 'prompt', 'profile'] as const) {
      const value = options[key];
      if (value !== undefined) parts.push({ name: key, value });
    }
    const reply = await this.#call('POST', '/v1/audio/transcriptions', { multipart: parts, signal: options.signal, timeoutMs: IMAGE_TIMEOUT }) as { text: string };
    return reply.text;
  }

  /** A 3D model (GLB) from an image and/or text. */
  async generate3D(body: { image?: { data: Buffer; filename?: string }; image_file_id?: string; prompt?: string; model?: string; profile?: string }, options: ImageOptions = {}): Promise<ImagesResponse | HubJob> {
    const { image, ...fields } = body;
    const headers: Record<string, string> = options.async ? { Prefer: 'respond-async' } : {};
    if (!image) return this.#call('POST', '/v1/3d/generations', { json: fields, signal: options.signal, timeoutMs: IMAGE_TIMEOUT, headers }) as Promise<ImagesResponse>;
    const parts: MultipartPart[] = Object.entries(fields).filter(([, v]) => v !== undefined).map(([name, v]) => ({ name, value: String(v) }));
    parts.push({ name: 'image', value: image.data, filename: image.filename ?? 'image.png', contentType: 'image/png' });
    return this.#call('POST', '/v1/3d/generations', { multipart: parts, signal: options.signal, timeoutMs: IMAGE_TIMEOUT, headers }) as Promise<ImagesResponse | HubJob>;
  }

  /** The latest live preview frame of a running job (when `has_preview`), or `null`. */
  async jobPreview(id: string, signal?: AbortSignal): Promise<Buffer | null> {
    const response = await this.#send('GET', `/v1/jobs/${encodeURIComponent(id)}/preview`, undefined, signal);
    if (response.statusCode === 404) { response.resume(); return null; }
    if (response.statusCode !== 200) throw await toError(response);
    return readBody(response, 32 * 1024 * 1024);
  }

  /**
   * Everything about this device as it happens: `job` (a job object), `session` (permissions changed on the Mac),
   * `revoked` (then the stream ends). Keep one open per app.
   */
  async *events(signal?: AbortSignal): AsyncGenerator<DeviceEvent> {
    const response = await this.#send('GET', '/v2/events', undefined, signal, { Accept: 'text/event-stream' }, 24 * 60 * 60_000);
    if (response.statusCode !== 200) throw await toError(response);
    let event = 'message';
    let buffer = '';
    for await (const chunk of response.setEncoding('utf8')) {
      buffer += chunk as string;
      let end: number;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end).trimEnd();
        buffer = buffer.slice(end + 1);
        if (line.startsWith('event:')) event = line.slice(6).trim();
        else if (line.startsWith('data:')) {
          const data = JSON.parse(line.slice(5).trim()) as unknown;
          if (event === 'job') yield { type: 'job', job: data as HubJob };
          else if (event === 'session') yield { type: 'session', scopes: (data as { scopes: string[] }).scopes };
          else if (event === 'revoked') { yield { type: 'revoked' }; return; }
          event = 'message';
        }
      }
    }
  }

  // MARK: Files (OpenAI `/v1/files`)

  async uploadFile(data: Buffer, filename: string, options: { purpose?: string; contentType?: string; signal?: AbortSignal } = {}): Promise<HubFile> {
    const parts: MultipartPart[] = [
      { name: 'file', value: data, filename, contentType: options.contentType ?? 'application/octet-stream' },
    ];
    if (options.purpose) parts.push({ name: 'purpose', value: options.purpose });
    return this.#call('POST', '/v1/files', { multipart: parts, signal: options.signal }) as Promise<HubFile>;
  }

  async files(signal?: AbortSignal): Promise<HubFile[]> {
    return ((await this.#call('GET', '/v1/files', { signal })) as { data: HubFile[] }).data;
  }

  async fileContent(id: string, signal?: AbortSignal): Promise<Buffer> {
    const response = await this.#send('GET', `/v1/files/${encodeURIComponent(id)}/content`, undefined, signal);
    if (response.statusCode !== 200) throw await toError(response);
    return readBody(response, 1024 * 1024 * 1024);
  }

  async deleteFile(id: string, signal?: AbortSignal): Promise<void> {
    await this.#call('DELETE', `/v1/files/${encodeURIComponent(id)}`, { signal });
  }

  // MARK: Jobs (hub extension `/v1/jobs`)

  async job(id: string, signal?: AbortSignal): Promise<HubJob> {
    return this.#call('GET', `/v1/jobs/${encodeURIComponent(id)}`, { signal }) as Promise<HubJob>;
  }

  async cancelJob(id: string, signal?: AbortSignal): Promise<HubJob> {
    return this.#call('POST', `/v1/jobs/${encodeURIComponent(id)}/cancel`, { signal }) as Promise<HubJob>;
  }

  async recipe(id: string, signal?: AbortSignal): Promise<JobRecipe> {
    return this.#call('GET', `/v1/jobs/${encodeURIComponent(id)}/recipe`, { signal }) as Promise<JobRecipe>;
  }

  async replayJob(id: string, variation = false, signal?: AbortSignal): Promise<HubJob> {
    return this.#call('POST', `/v1/jobs/${encodeURIComponent(id)}/replay`, { json: { variation }, signal }) as Promise<HubJob>;
  }

  /** Job snapshots until it completes, fails or is cancelled. */
  async *jobEvents(id: string, signal?: AbortSignal): AsyncGenerator<HubJob> {
    const response = await this.#send('GET', `/v1/jobs/${encodeURIComponent(id)}/events`, undefined, signal,
      { Accept: 'text/event-stream' }, IMAGE_TIMEOUT);
    if (response.statusCode !== 200) throw await toError(response);
    for await (const data of sseData(response)) yield JSON.parse(data) as HubJob;
  }

  async request(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<unknown> {
    return this.#call(method, path, { ...(body !== undefined ? { json: body } : {}), signal });
  }

  /**
   * Finds the paired hub again after its IP changed: Bonjour, matched by hub id and the pinned
   * fingerprint. Saves and returns the new address, or `null` if it is not on the network.
   * Requests call this once on their own when the hub is unreachable.
   */
  async relocate(timeoutMs = 2500): Promise<string | null> {
    const session = this.#require();
    if (!session.hubID) return null;
    const hub = (await discoverHubs({ timeoutMs })).find((h) => h.id === session.hubID && h.fingerprint === session.fingerprint);
    if (!hub) return null;
    const address = new URL(`https://${hub.host}:${hub.port}`).origin;
    if (address === session.address) return null;
    this.#session = { ...session, address };
    await this.store.save(this.#session);
    return address;
  }

  #require(): HubSession {
    if (!this.#session) throw new Error('LocalHub is not paired');
    return this.#session;
  }

  #send(method: string, path: string, body: unknown, signal?: AbortSignal,
        headers: Record<string, string> = {}, timeoutMs?: number): Promise<IncomingMessage> {
    const session = this.#require();
    return send(new URL(session.address), session.fingerprint, session.token, method, path,
      body === undefined ? {} : { json: body }, signal, headers, timeoutMs);
  }

  async #call(method: string, path: string, options: CallOptions): Promise<unknown> {
    const session = this.#require();
    try {
      return await this.#json(new URL(session.address), session.fingerprint, session.token, method, path, options);
    } catch (error) {
      if (!isUnreachable(error) || !(await this.relocate())) throw error;
      const moved = this.#require();
      return this.#json(new URL(moved.address), moved.fingerprint, moved.token, method, path, options);
    }
  }

  async #json(address: URL, fingerprint: string, token: string | null, method: string, path: string,
              options: CallOptions): Promise<unknown> {
    const response = await send(address, fingerprint, token, method, path, options, options.signal,
      { Accept: 'application/json', ...options.headers }, options.timeoutMs);
    if (response.statusCode === 204) {
      response.resume();
      return null;
    }
    if (response.statusCode !== 200 && response.statusCode !== 202) throw await toError(response);
    return JSON.parse((await readBody(response, 64 * 1024 * 1024)).toString('utf8'));
  }
}

const IMAGE_TIMEOUT = 11 * 60_000;

interface CallOptions {
  json?: unknown;
  multipart?: MultipartPart[];
  signal?: AbortSignal | undefined;
  headers?: Record<string, string>;
  timeoutMs?: number;
}

export interface MultipartPart {
  name: string;
  value: string | Buffer;
  filename?: string;
  contentType?: string;
}

export interface ImageOptions {
  signal?: AbortSignal;
  /** Return a queued job (202) instead of waiting for the image. */
  async?: boolean;
}

export interface ImageGenerateRequest {
  profile?: string;
  priority?: number;
  schedule?: 'anytime' | 'night';
  prompt: string;
  /** `<integration>/<workflow>` from `models()`; omitted = the Mac's default. */
  model?: string;
  size?: string;
  response_format?: 'b64_json' | 'url';
  negative_prompt?: string;
  seed?: number;
  steps?: number;
}

export interface ImageEditRequest extends ImageGenerateRequest {
  /** PNG; transparent pixels are the area to repaint unless a mask is given. */
  image?: { data: Buffer; filename?: string };
  mask?: { data: Buffer; filename?: string };
  image_file_id?: string;
  mask_file_id?: string;
  strength?: number;
}

export interface AudioGenerateRequest {
  profile?: string;
  priority?: number;
  schedule?: 'anytime' | 'night';
  prompt: string;
  model?: string;
  seconds?: number;
  negative_prompt?: string;
  seed?: number;
  steps?: number;
  response_format?: 'b64_json' | 'url';
}

export interface VideoCreateRequest {
  profile?: string;
  priority?: number;
  schedule?: 'anytime' | 'night';
  prompt: string;
  model?: string;
  /** OpenAI sends it as a string ("8"); numbers work too. Frames = seconds × the workflow's fps. */
  seconds?: string | number;
  size?: string;
  negative_prompt?: string;
  seed?: number;
  steps?: number;
  image_file_id?: string;
}

export type DeviceEvent = { type: 'job'; job: HubJob } | { type: 'session'; scopes: string[] } | { type: 'revoked' };

export interface HubVideo {
  id: string;
  object: 'video';
  status: 'queued' | 'in_progress' | 'completed' | 'failed';
  progress: number;
  created_at: number;
  completed_at?: number;
  model: string;
  file_id?: string;
  error?: { code: string; message: string };
}

export interface ImagesResponse {
  created: number;
  data: { b64_json?: string; url?: string; file_id: string }[];
}

export interface HubFile {
  id: string;
  object: 'file';
  bytes: number;
  created_at: number;
  filename: string;
  purpose: string;
  mime_type: string;
  source: 'upload' | 'job';
  job_id?: string;
}

export interface HubJob {
  id: string;
  object: 'job';
  status: 'queued' | 'in_progress' | 'completed' | 'failed' | 'cancelled';
  capability: string;
  model: string;
  progress?: number;
  error?: string;
  output_file_ids: string[];
  created_at: number;
  started_at?: number;
  finished_at?: number;
  /** Prompts ahead in ComfyUI's queue while queued. */
  queue_position?: number;
  current_node?: string;
  eta_seconds?: number;
  waiting_reason?: string;
  has_preview?: boolean;
  has_recipe?: boolean;
}

export interface JobRecipe {
  schemaVersion: number;
  workflowName: string;
  workflowVersion: string;
  parameters: {
    prompt: string; negativePrompt?: string; seed?: number; steps?: number;
    width?: number; height?: number; denoise?: number; seconds?: number; frames?: number; fps?: number;
  };
  inputs: Array<{ kind: string; fileID: string; filename: string; sha256: string }>;
  modelFiles: string[];
  parentJobID?: string;
  workProfileID?: string;
  workProfileName?: string;
}

function send(address: URL, fingerprint: string, token: string | null, method: string, path: string,
              body: { json?: unknown; multipart?: MultipartPart[] }, signal: AbortSignal | undefined,
              headers: Record<string, string>, timeoutMs?: number): Promise<IncomingMessage> {
  if (!path.startsWith('/') || path.startsWith('//')) throw new Error('LocalHub paths are relative to the paired hub');
  const allHeaders: Record<string, string> = { ...headers };
  if (token) allHeaders.Authorization = `Bearer ${token}`;
  let payload: Buffer | undefined;
  if (body.multipart) {
    const boundary = `localhub-${randomUUID()}`;
    payload = multipart(body.multipart, boundary);
    allHeaders['Content-Type'] = `multipart/form-data; boundary=${boundary}`;
  } else if (body.json !== undefined) {
    payload = Buffer.from(JSON.stringify(body.json));
    allHeaders['Content-Type'] = 'application/json';
  }
  if (payload) allHeaders['Content-Length'] = String(payload.length);
  return pinnedRequest(address, fingerprint, {
    method, path, headers: allHeaders,
    ...(payload !== undefined ? { body: payload } : {}),
    ...(signal ? { signal } : {}),
    ...(timeoutMs ? { timeoutMs } : {}),
  });
}

function multipart(parts: MultipartPart[], boundary: string): Buffer {
  const chunks: Buffer[] = [];
  for (const part of parts) {
    const name = part.name.replace(/["\r\n]/g, '');
    let head = `--${boundary}\r\nContent-Disposition: form-data; name="${name}"`;
    if (part.filename !== undefined) head += `; filename="${part.filename.replace(/["\r\n]/g, '')}"`;
    if (part.contentType) head += `\r\nContent-Type: ${part.contentType}`;
    chunks.push(Buffer.from(`${head}\r\n\r\n`), Buffer.isBuffer(part.value) ? part.value : Buffer.from(part.value), Buffer.from('\r\n'));
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(chunks);
}

async function* sseData(response: IncomingMessage): AsyncGenerator<string> {
  let buffer = '';
  for await (const chunk of response.setEncoding('utf8')) {
    buffer += chunk as string;
    let end: number;
    while ((end = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, end).trimEnd();
      buffer = buffer.slice(end + 1);
      if (line.startsWith('data:')) yield line.slice(5).trim();
    }
    if (buffer.length > 1024 * 1024) throw new Error('LocalHub stream line too long');
  }
}

function isUnreachable(error: unknown): boolean {
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  return ['ECONNREFUSED', 'EHOSTUNREACH', 'ENETUNREACH', 'ETIMEDOUT', 'EHOSTDOWN'].includes(code ?? '');
}

async function toError(response: IncomingMessage): Promise<HubRequestError> {
  const status = response.statusCode ?? 0;
  try {
    const parsed = JSON.parse((await readBody(response, 64 * 1024)).toString('utf8')) as
      { error?: { code?: string; message?: string; provider?: string } };
    const e = parsed.error;
    if (e?.code && e.message) return new HubRequestError(status, e.code, e.message, e.provider);
  } catch {
    // Fall through to a generic error.
  }
  return new HubRequestError(status, 'http_error', `LocalHub HTTP ${status}`);
}

export interface WorkProfile {
  id: string; name: string; models: Record<string, string>;
  steps?: number; width?: number; height?: number; negativePrompt?: string; seconds?: number; fps?: number;
  priority?: number; schedule?: 'anytime' | 'night';
}
