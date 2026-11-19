import { chmod, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { HubSession } from './client.ts';

export interface SessionStore {
  load(): Promise<HubSession | null>;
  save(session: HubSession): Promise<void>;
  clear(): Promise<void>;
}

export class MemorySessionStore implements SessionStore {
  #session: HubSession | null = null;
  async load() {
    return this.#session;
  }
  async save(session: HubSession) {
    this.#session = session;
  }
  async clear() {
    this.#session = null;
  }
}

/** The subset of Electron's `safeStorage` this store needs (injected, so no Electron dependency). */
export interface SafeStorageLike {
  isEncryptionAvailable(): boolean;
  encryptString(plain: string): Buffer;
  decryptString(encrypted: Buffer): string;
}

/**
 * Keychain-backed (via Electron `safeStorage`) session file, e.g. in
 * `app.getPath('userData')`. Refuses to write a bearer token in plain text.
 */
export class SafeStorageSessionStore implements SessionStore {
  readonly safeStorage: SafeStorageLike;
  readonly path: string;

  constructor(safeStorage: SafeStorageLike, path: string) {
    this.safeStorage = safeStorage;
    this.path = path;
  }

  async load(): Promise<HubSession | null> {
    let data: Buffer;
    try {
      data = await readFile(this.path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null;
      throw error;
    }
    return JSON.parse(this.safeStorage.decryptString(data)) as HubSession;
  }

  async save(session: HubSession): Promise<void> {
    if (!this.safeStorage.isEncryptionAvailable()) throw new Error('Secure storage is not available on this system');
    await mkdir(dirname(this.path), { recursive: true, mode: 0o700 });
    const temporary = `${this.path}.${process.pid}.tmp`;
    await writeFile(temporary, this.safeStorage.encryptString(JSON.stringify(session)), { mode: 0o600 });
    await chmod(temporary, 0o600);
    await rename(temporary, this.path);
  }

  async clear(): Promise<void> {
    await rm(this.path, { force: true });
  }
}
