import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'discovery.dart';
import 'invite.dart';
import 'pinned.dart';
import 'session.dart';

/// The hub's `{"error": {code, message, provider?}}`, e.g. `provider_unavailable`
/// when LM Studio is closed on the Mac.
class HubException implements Exception {
  const HubException(this.status, this.code, this.message, {this.provider});
  final int status;
  final String code, message;
  final String? provider;
  @override
  String toString() => 'HubException($status $code): $message';
}

/// One event from `/v2/events`: `job` (data is a job), `session` (data has `scopes`) or `revoked`.
class DeviceEvent {
  const DeviceEvent(this.type, this.data);
  final String type;
  final Map<String, Object?> data;
}

/// An input file for edits: raw bytes, or a file already on the hub.
class HubInput {
  const HubInput.bytes(Uint8List this.bytes, {this.filename = 'image.png', this.contentType = 'image/png'}) : fileID = null;
  const HubInput.file(String this.fileID)
      : bytes = null,
        filename = '',
        contentType = '';
  final Uint8List? bytes;
  final String? fileID;
  final String filename, contentType;
}

class HubClient {
  HubClient(this.store);

  final SessionStore store;
  HubSession? _session;
  final Set<HttpClient> _open = {};

  HubSession? get session => _session;

  static const _jsonLimit = 64 * 1024 * 1024;
  static const _mediaTimeout = Duration(minutes: 11);

  Future<HubSession?> restore() async => _session = await store.load();

  Future<HubSession> pair(HubInvite invite, {required String deviceName, required String app, List<String>? scopes}) async {
    final result = await _request(invite.address, invite.fingerprint, null, 'POST', invite.version == 2 ? '/v2/pair' : '/pair',
        json: {'code': invite.code, 'deviceName': deviceName.trim(), 'app': app, 'scopes': ?scopes}) as Map<String, Object?>;
    final paired = HubSession.fromJson({
      ...result,
      'address': invite.address.toString(),
      'fingerprint': invite.fingerprint,
      'hubID': invite.hubID,
      'hubName': invite.hubName,
    });
    await store.save(paired);
    return _session = paired;
  }

  Future<void> unpair() async {
    if (_session != null) {
      try {
        await _call('DELETE', '/v2/session');
      } on HubException catch (error) {
        if (error.status != 401) rethrow;
      }
    }
    await store.clear();
    _session = null;
  }

  Future<List<Map<String, Object?>>> models() async => _list(await _call('GET', '/v1/models'));
  Future<List<Map<String, Object?>>> workProfiles() async => _list(await _call('GET', '/v2/profiles'));

  Future<List<Map<String, Object?>>> integrations() async => _list(await _call('GET', '/v2/integrations'));

  Future<Map<String, Object?>> chat(Map<String, Object?> body) async =>
      await _call('POST', '/v1/chat/completions', json: {...body, 'stream': false}) as Map<String, Object?>;

  /// OpenAI `chat.completion.chunk` maps. Cancelling the subscription closes the
  /// connection, and the hub stops the generation on the Mac.
  Stream<Map<String, Object?>> chatStream(Map<String, Object?> body) =>
      _sse('POST', '/v1/chat/completions', json: {...body, 'stream': true}).takeWhile((data) => data != '[DONE]').map(_decodeMap);

  // Images, audio and video. Local workflows can take minutes; [async] returns a job right away.

  Future<Map<String, Object?>> generateImage(Map<String, Object?> body, {bool async = false}) =>
      _media('/v1/images/generations', body, async: async);

  /// [image] with transparent pixels marks the area to repaint, unless [mask] is given.
  Future<Map<String, Object?>> editImage(Map<String, Object?> fields, {required HubInput image, HubInput? mask, bool async = false}) =>
      _media('/v1/images/edits', fields, async: async, inputs: {'image': image, 'mask': ?mask});

  Future<Map<String, Object?>> generateAudio(Map<String, Object?> body, {bool async = false}) =>
      _media('/v1/audio/generations', body, async: async);

  /// Speech bytes (e.g. FLAC or WAV, per the Mac's workflow).
  Future<Uint8List> speech(String input, {String? model, String? voice, String? profile}) async {
    return _bytes('POST', '/v1/audio/speech', json: {'input': input, 'model': ?model, 'voice': ?voice, 'profile': ?profile},
        timeout: _mediaTimeout, limit: 256 * 1024 * 1024);
  }

  /// Always asynchronous, like OpenAI's videos API: poll [video] or follow [jobEvents].
  Future<Map<String, Object?>> createVideo(Map<String, Object?> body, {HubInput? image}) async =>
      await _media('/v1/videos', body, async: true, inputs: {'input_reference': ?image});
  Future<Map<String, Object?>> video(String id) async => await _call('GET', '/v1/videos/${Uri.encodeComponent(id)}') as Map<String, Object?>;
  Future<Uint8List> videoContent(String id) => _bytes('GET', '/v1/videos/${Uri.encodeComponent(id)}/content');

  Future<List<List<double>>> embeddings(String model, List<String> input, {String? profile}) async {
    final reply = await _call('POST', '/v1/embeddings', json: {'model': model, 'input': input, 'profile': ?profile}) as Map;
    return [for (final item in reply['data'] as List) [for (final v in (item as Map)['embedding'] as List) (v as num).toDouble()]];
  }

  /// whisper.cpp or an OpenAI-style transcription server on the Mac.
  Future<String> transcribe(Uint8List audio, {String filename = 'audio.wav', String? model, String? language, String? profile}) async {
    final reply = await _call('POST', '/v1/audio/transcriptions', timeout: _mediaTimeout, multipart: [
      _Part.file('file', audio, filename, 'application/octet-stream'),
      if (model != null) _Part.field('model', model),
      if (language != null) _Part.field('language', language),
      if (profile != null) _Part.field('profile', profile),
    ]) as Map;
    return reply['text'] as String? ?? '';
  }

  /// A 3D model (GLB) from an image and/or text.
  Future<Map<String, Object?>> generate3D({HubInput? image, String? prompt, String? model, String? profile, bool async = false}) =>
      _media('/v1/3d/generations', {'prompt': ?prompt, 'model': ?model, 'profile': ?profile}, async: async, inputs: {'image': ?image});

  /// The latest live preview frame of a running job (when `has_preview`), or `null`.
  Future<Uint8List?> jobPreview(String id) async {
    try {
      return await _bytes('GET', '/v1/jobs/${Uri.encodeComponent(id)}/preview', limit: 32 * 1024 * 1024);
    } on HubException catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  /// Everything about this device as it happens: `job` events (job maps), `session` (new scopes), `revoked`.
  Stream<DeviceEvent> deviceEvents() async* {
    final session = _require();
    final (response, client) = await _send(session.address, session.fingerprint, session.token, 'GET', '/v2/events',
        headers: {'Accept': 'text/event-stream'}, timeout: const Duration(hours: 24));
    var event = 'message';
    try {
      await for (final line in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          final data = _decodeMap(line.substring(5).trim());
          yield DeviceEvent(event, data);
          if (event == 'revoked') return;
          event = 'message';
        }
      }
    } finally {
      _done(client, force: true);
    }
  }

  // Files

  Future<Map<String, Object?>> uploadFile(Uint8List bytes, String filename, {String contentType = 'application/octet-stream', String? purpose}) async =>
      await _call('POST', '/v1/files', multipart: [
        _Part.file('file', bytes, filename, contentType),
        if (purpose != null) _Part.field('purpose', purpose),
      ]) as Map<String, Object?>;
  Future<List<Map<String, Object?>>> files() async => _list(await _call('GET', '/v1/files'));
  Future<Uint8List> fileContent(String id) => _bytes('GET', '/v1/files/${Uri.encodeComponent(id)}/content');
  Future<void> deleteFile(String id) async => _call('DELETE', '/v1/files/${Uri.encodeComponent(id)}');

  // Jobs

  Future<Map<String, Object?>> job(String id) async => await _call('GET', '/v1/jobs/${Uri.encodeComponent(id)}') as Map<String, Object?>;
  Future<Map<String, Object?>> cancelJob(String id) async =>
      await _call('POST', '/v1/jobs/${Uri.encodeComponent(id)}/cancel') as Map<String, Object?>;

  Future<Map<String, Object?>> recipe(String id) async =>
      await _call('GET', '/v1/jobs/${Uri.encodeComponent(id)}/recipe') as Map<String, Object?>;
  Future<Map<String, Object?>> replayJob(String id, {bool variation = false}) async =>
      await _call('POST', '/v1/jobs/${Uri.encodeComponent(id)}/replay', json: {'variation': variation}) as Map<String, Object?>;

  /// Job snapshots until it completes, fails or is cancelled.
  Stream<Map<String, Object?>> jobEvents(String id) => _sse('GET', '/v1/jobs/${Uri.encodeComponent(id)}/events').map(_decodeMap);

  // MCP tools on this Mac (each server needs the `mcp:<id>` scope)

  /// Servers this device may use: `[{id, transport, allowedTools}]`.
  Future<List<Map<String, Object?>>> mcpServers() async => _list(await _call('GET', '/v2/mcp/servers'));

  /// The server's allowlisted tools with their input schemas: `[{name, description, inputSchema}]`.
  Future<List<Map<String, Object?>>> mcpTools(String server) async {
    final json = await _call('GET', '/v2/mcp/${Uri.encodeComponent(server)}/tools') as Map<String, Object?>;
    return _list(json['tools']);
  }

  /// Runs one tool: `{content, isError}`. Throws [HubException] `forbidden` (403) for a tool outside the
  /// Mac's allowlist and `bad_request` (400) when [arguments] do not match its schema.
  Future<Map<String, Object?>> mcpCall(String server, String tool, Map<String, Object?> arguments) async =>
      await _call('POST', '/v2/mcp/${Uri.encodeComponent(server)}/call', json: {'name': tool, 'arguments': arguments})
          as Map<String, Object?>;

  /// Closes every open connection (e.g. when the screen using the hub goes away).
  void close() {
    for (final client in _open.toList()) {
      client.close(force: true);
    }
    _open.clear();
  }

  // MARK: plumbing

  Future<Map<String, Object?>> _media(String path, Map<String, Object?> body,
      {required bool async, Map<String, HubInput> inputs = const {}}) async {
    final headers = async ? {'Prefer': 'respond-async'} : const <String, String>{};
    final uploads = inputs.entries.where((e) => e.value.bytes != null).toList();
    if (uploads.isEmpty) {
      final json = {...body, for (final e in inputs.entries) '${e.key == 'input_reference' ? 'image' : e.key}_file_id': e.value.fileID};
      return await _call('POST', path, json: json, headers: headers, timeout: _mediaTimeout) as Map<String, Object?>;
    }
    return await _call('POST', path, headers: headers, timeout: _mediaTimeout, multipart: [
      for (final entry in body.entries)
        if (entry.value != null) _Part.field(entry.key, '${entry.value}'),
      for (final entry in inputs.entries)
        if (entry.value.bytes != null)
          _Part.file(entry.key, entry.value.bytes!, entry.value.filename, entry.value.contentType)
        else
          _Part.field('${entry.key}_file_id', entry.value.fileID!),
    ]) as Map<String, Object?>;
  }

  /// Finds the paired hub again after its IP changed (Bonjour, matched by hub id and the pinned
  /// fingerprint). Saves and returns the new address, or `null`. Requests do this once by themselves.
  Future<Uri?> relocate({Duration timeout = const Duration(milliseconds: 2500)}) async {
    final session = _require();
    if (session.hubID == null) return null;
    final match = (await discoverHubs(timeout: timeout))
        .where((hub) => hub.id == session.hubID && hub.fingerprint == session.fingerprint)
        .firstOrNull;
    if (match == null) return null;
    final address = Uri(scheme: 'https', host: match.host, port: match.port);
    if (address == session.address) return null;
    final moved = HubSession.fromJson({...session.toJson(), 'address': address.toString()});
    await store.save(moved);
    _session = moved;
    return address;
  }

  HubSession _require() => _session ?? (throw StateError('LocalHub is not paired'));

  Future<Object?> _call(String method, String path,
      {Object? json, List<_Part>? multipart, Map<String, String> headers = const {}, Duration? timeout}) async {
    final session = _require();
    try {
      return await _request(session.address, session.fingerprint, session.token, method, path,
          json: json, multipart: multipart, headers: headers, timeout: timeout);
    } on SocketException {
      if (await relocate() == null) rethrow;
      final moved = _require();
      return _request(moved.address, moved.fingerprint, moved.token, method, path,
          json: json, multipart: multipart, headers: headers, timeout: timeout);
    }
  }

  Future<Object?> _request(Uri address, String fingerprint, String? token, String method, String path,
      {Object? json, List<_Part>? multipart, Map<String, String> headers = const {}, Duration? timeout}) async {
    final (response, client) = await _send(address, fingerprint, token, method, path,
        json: json, multipart: multipart, headers: {'Accept': 'application/json', ...headers}, timeout: timeout);
    try {
      if (response.statusCode == 204) {
        await response.drain<void>();
        return null;
      }
      final bytes = await _readBytes(response, limit: _jsonLimit);
      return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
    } finally {
      _done(client);
    }
  }

  Future<Uint8List> _bytes(String method, String path, {Object? json, Duration? timeout, int limit = 1024 * 1024 * 1024}) async {
    final session = _require();
    final (response, client) =
        await _send(session.address, session.fingerprint, session.token, method, path, json: json, timeout: timeout);
    try {
      return await _readBytes(response, limit: limit);
    } finally {
      _done(client);
    }
  }

  Stream<String> _sse(String method, String path, {Object? json}) async* {
    final session = _require();
    final (response, client) = await _send(session.address, session.fingerprint, session.token, method, path,
        json: json, headers: {'Accept': 'text/event-stream'}, timeout: _mediaTimeout);
    try {
      await for (final line in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.startsWith('data:')) yield line.substring(5).trim();
      }
    } finally {
      // Runs on cancel too: closing the socket tells the hub to stop the upstream work.
      _done(client, force: true);
    }
  }

  void _done(HttpClient client, {bool force = false}) {
    client.close(force: force);
    _open.remove(client);
  }

  Future<(HttpClientResponse, HttpClient)> _send(Uri address, String fingerprint, String? token, String method, String path,
      {Object? json, List<_Part>? multipart, Map<String, String> headers = const {}, Duration? timeout}) async {
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw ArgumentError('LocalHub paths are relative to the paired hub');
    }
    final client = pinnedHttpClient(address, fingerprint)..idleTimeout = timeout ?? const Duration(seconds: 120);
    _open.add(client);
    try {
      final request = await client.openUrl(method, address.replace(path: path)).timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (multipart != null) {
        final boundary = 'localhub-${Random.secure().nextInt(1 << 32)}${DateTime.now().microsecondsSinceEpoch}';
        final body = _Part.encode(multipart, boundary);
        request.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
        request.contentLength = body.length;
        request.add(body);
      } else if (json != null) {
        final body = utf8.encode(jsonEncode(json));
        request.headers.contentType = ContentType.json;
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(timeout ?? const Duration(seconds: 120));
      if (response.statusCode != 200 && response.statusCode != 202 && response.statusCode != 204) {
        throw await _error(response);
      }
      return (response, client);
    } catch (_) {
      _done(client, force: true);
      rethrow;
    }
  }

  static Future<Uint8List> _readBytes(HttpClientResponse response, {required int limit}) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (builder.length + chunk.length > limit) throw const FormatException('LocalHub response too large');
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Future<HubException> _error(HttpClientResponse response) async {
    try {
      final body = jsonDecode(utf8.decode(await _readBytes(response, limit: 64 * 1024)));
      final error = (body as Map)['error'] as Map;
      return HubException(response.statusCode, error['code'] as String, error['message'] as String,
          provider: error['provider'] as String?);
    } catch (_) {
      return HubException(response.statusCode, 'http_error', 'LocalHub HTTP ${response.statusCode}');
    }
  }

  static Map<String, Object?> _decodeMap(String data) => (jsonDecode(data) as Map).cast<String, Object?>();
  /// OpenAI lists are `{"object": "list", "data": [...]}`; hub `/v2` lists are bare arrays.
  static List<Map<String, Object?>> _list(Object? json) =>
      (json is Map ? json['data'] as List : json as List).map((e) => (e as Map).cast<String, Object?>()).toList();
}

class _Part {
  _Part.field(this.name, String value)
      : bytes = utf8.encode(value),
        filename = null,
        contentType = null;
  _Part.file(this.name, Uint8List this.bytes, String this.filename, String this.contentType);

  final String name;
  final List<int> bytes;
  final String? filename, contentType;

  static Uint8List encode(List<_Part> parts, String boundary) {
    String clean(String value) => value.replaceAll(RegExp(r'["\r\n]'), '');
    final out = BytesBuilder();
    for (final part in parts) {
      var head = '--$boundary\r\nContent-Disposition: form-data; name="${clean(part.name)}"';
      if (part.filename != null) head += '; filename="${clean(part.filename!)}"';
      if (part.contentType != null) head += '\r\nContent-Type: ${part.contentType}';
      out
        ..add(utf8.encode('$head\r\n\r\n'))
        ..add(part.bytes)
        ..add(utf8.encode('\r\n'));
    }
    out.add(utf8.encode('--$boundary--\r\n'));
    return out.takeBytes();
  }
}
