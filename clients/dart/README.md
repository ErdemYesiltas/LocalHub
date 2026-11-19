# localhub_client (Dart)

Pure Dart LocalHub client for ArtBlend and other Dart/Flutter apps. Grew out of ArtBlend's Companion client
(`companion_transport.dart`, `companion_invite.dart`, `companion_service.dart`).

- `HubInvite.parse` — `localhub://pair?v=2…` and legacy `artblend-companion://pair?v=1…`
- `pinnedHttpClient` — `HttpClient(SecurityContext(withTrustedRoots: false))`; the `badCertificateCallback`
  accepts only the paired SHA-256, host and port, in date, before any request bytes are written
- `HubClient` — `pair`, `unpair`, `models`, `integrations`, `chat`, `chatStream`, `generateImage`, `editImage`,
  `generateAudio`, `speech`, `createVideo`, `video`, `videoContent`, `uploadFile`, `files`, `fileContent`,
  `deleteFile`, `job`, `cancelJob`, `jobEvents`, `jobPreview`, `deviceEvents`, `embeddings`, `transcribe`,
  `generate3D`, `relocate`, `mcpServers`, `mcpTools`, `mcpCall`
- `HubException(status, code, message, provider)` — e.g. `provider_unavailable` when LM Studio is closed
- `SessionStore` — implement with `flutter_secure_storage` in the app; `MemorySessionStore` for tests

```dart
final hub = HubClient(SecureSessionStore());          // your flutter_secure_storage implementation
await hub.restore();
await hub.pair(HubInvite.parse(scannedText), deviceName: 'MatePad 11', app: 'artblend');
final edited = await hub.editImage({'prompt': 'add a hat'}, image: HubInput.bytes(canvasPng));
```

In ArtBlend's `pubspec.yaml`: `localhub_client: { path: ../../../localhub/clients/dart }` (adjust the path).

```bash
dart pub get && dart test && dart analyze
dart run example/list_models.dart '<invite from the hub>'
```

See [Integrate a client](../../README.md#integrate-a-client) and the [OpenAPI specification](../../api/openapi.yaml).
