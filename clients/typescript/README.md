# @localhub/client

LocalHub client for Node and the Electron **main process**: QR invite parsing, SHA-256 certificate pinning
verified before any HTTP byte is sent, pairing, OpenAI-compatible models/chat with streaming and abort, and a
`safeStorage`-backed session store.

```ts
import { safeStorage, app, ipcMain } from 'electron';
import { HubClient, SafeStorageSessionStore, parseInvite } from '@localhub/client';

const hub = new HubClient(new SafeStorageSessionStore(safeStorage, `${app.getPath('userData')}/localhub.bin`));
await hub.restore();

// The renderer sends invite text (scanned QR or typed) and never sees the token.
ipcMain.handle('localhub:pair', async (_event, inviteText: string) => {
  const session = await hub.pair(parseInvite(inviteText), { deviceName: 'Olive Studio', app: 'olive-studio' });
  return { hubName: session.hubName, scopes: session.scopes };
});
ipcMain.handle('localhub:models', () => hub.models());
```

`pnpm test` runs the pairing, pinning, streaming and session-store tests against a local self-signed HTTPS server.
Requires Node ≥ 22.18 (runs TypeScript sources directly via type stripping).

See [Integrate a client](../../README.md#integrate-a-client) and the [OpenAPI specification](../../api/openapi.yaml).
