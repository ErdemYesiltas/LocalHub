import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localhub_client/localhub_client.dart';
import 'package:test/test.dart';

const token = 'TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT';
final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

class Recorded {
  Recorded(this.method, this.path, this.authorization, this.contentType, this.body);
  final String method, path;
  final String? authorization, contentType;
  final String body;
}

late HttpServer server;
late String fingerprint;
final requests = <Recorded>[];

Future<void> json(HttpRequest request, int status, Object body) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await request.response.close();
}

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('localhub-dart-');
    final result = await Process.run('/usr/bin/openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=LocalHub',
      '-keyout', '${dir.path}/key.pem', '-out', '${dir.path}/cert.pem',
    ]);
    expect(result.exitCode, 0);
    final certPem = await File('${dir.path}/cert.pem').readAsString();
    final keyPem = await File('${dir.path}/key.pem').readAsBytes();
    await dir.delete(recursive: true);
    final der = base64.decode(certPem.split('\n').where((l) => l.isNotEmpty && !l.startsWith('-----')).join());
    fingerprint = sha256.convert(der).toString();

    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certPem))
      ..usePrivateKeyBytes(keyPem);
    server = await HttpServer.bindSecure('127.0.0.1', 0, context);
    server.listen((request) async {
      final body = await const Utf8Decoder(allowMalformed: true).bind(request).join();
      requests.add(Recorded(request.method, request.uri.path, request.headers.value('authorization'),
          request.headers.value('content-type'), body));
      final authed = request.headers.value('authorization') == 'Bearer $token';
      switch ('${request.method} ${request.uri.path}') {
        case 'POST /v2/pair':
          final input = jsonDecode(body) as Map;
          if (input['code'] != '123456') return json(request, 401, {'error': {'code': 'wrong_code', 'message': 'Wrong pairing code'}});
          return json(request, 200, {'deviceID': 'dev-1', 'token': token, 'scopes': ['chat', 'image.edit']});
        case 'GET /v1/models':
          if (!authed) return json(request, 401, {'error': {'code': 'unauthorized', 'message': 'Pair first'}});
          return json(request, 200, {'object': 'list', 'data': [{'id': 'lmstudio/qwen', 'capabilities': ['chat']}]});
        case 'POST /v1/chat/completions':
          final input = jsonDecode(body) as Map;
          if ((input['model'] as String).startsWith('ollama/')) {
            return json(request, 503, {'error': {'code': 'provider_unavailable', 'message': 'Ollama is not running on this Mac', 'provider': 'ollama'}});
          }
          request.response.headers.contentType = ContentType('text', 'event-stream');
          request.response
            ..write('data: {"choices":[{"delta":{"content":"Mer"}}]}\n\n')
            ..write('data: {"choices":[{"delta":{"content":"haba"}}]}\n\n')
            ..write('data: [DONE]\n\n');
          return request.response.close();
        case 'POST /v1/images/edits':
          return json(request, 200, {'created': 1, 'data': [{'b64_json': base64.encode(png), 'file_id': 'file-1'}]});
        case 'GET /v1/files/file-1/content':
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(png);
          return request.response.close();
        case 'GET /v1/jobs/job-1/events':
          request.response.headers.contentType = ContentType('text', 'event-stream');
          request.response
            ..write('event: progress\ndata: {"id":"job-1","status":"in_progress","progress":0.5}\n\n')
            ..write('event: completed\ndata: {"id":"job-1","status":"completed","output_file_ids":["file-1"]}\n\n');
          return request.response.close();
        case 'GET /v1/jobs/job-1/recipe':
          return json(request, 200, {'schemaVersion': 1, 'workflowName': 'SDXL', 'parameters': {'prompt': 'a fox', 'seed': 42}, 'inputs': [], 'modelFiles': []});
        case 'POST /v1/jobs/job-1/replay':
          return json(request, 200, {'id': 'job-replay', 'status': 'queued', 'variation': (jsonDecode(body) as Map)['variation']});
        case 'GET /v2/integrations':
          return json(request, 200, [{'id': 'lmstudio', 'state': 'running'}]);
        case 'GET /v2/profiles':
          return json(request, 200, [{'id': 'draft', 'name': 'Quick Draft', 'models': {}, 'steps': 4}]);
        case 'POST /v1/embeddings':
          return json(request, 200, {'data': [{'embedding': [0.1, 0.2]}]});
        case 'POST /v1/audio/transcriptions':
          return json(request, 200, {'text': 'merhaba dünya'});
        case 'GET /v1/jobs/job-1/preview':
          request.response.headers.contentType = ContentType('image', 'jpeg');
          request.response.add(utf8.encode('jpeg'));
          return request.response.close();
        case 'GET /v2/events':
          request.response.headers.contentType = ContentType('text', 'event-stream');
          request.response
            ..write(': connected\n\n')
            ..write('event: job\ndata: {"id":"job-1","status":"in_progress","current_node":"KSampler 3/20"}\n\n')
            ..write('event: session\ndata: {"scopes":["chat"]}\n\n')
            ..write('event: revoked\ndata: {}\n\n');
          return request.response.close();
        case 'GET /v2/mcp/servers':
          return json(request, 200, [{'id': 'my tools', 'transport': 'stdio', 'allowedTools': ['echo']}]);
        case 'GET /v2/mcp/my%20tools/tools':
          return json(request, 200, {'tools': [{'name': 'echo', 'description': 'Echo', 'inputSchema': {'type': 'object'}}]});
        case 'POST /v2/mcp/my%20tools/call':
          final input = jsonDecode(body) as Map;
          if (input['name'] != 'echo') return json(request, 403, {'error': {'code': 'forbidden', 'message': "Tool is not in this Mac's allowlist"}});
          if ((input['arguments'] as Map).isEmpty) return json(request, 400, {'error': {'code': 'bad_request', 'message': 'Arguments do not match the tool schema'}});
          return json(request, 200, {'content': [{'type': 'text', 'text': (input['arguments'] as Map)['text']}], 'isError': false});
        case 'DELETE /v2/session':
          request.response.statusCode = 204;
          return request.response.close();
        default:
          return json(request, 404, {'error': {'code': 'not_found', 'message': 'nope'}});
      }
    });
  });

  tearDownAll(() => server.close(force: true));

  HubInvite invite({String? fp, String code = '123456'}) => HubInvite.parse(
      'localhub://pair?v=2&u=${Uri.encodeComponent('https://127.0.0.1:${server.port}')}&fp=${fp ?? fingerprint}&c=$code&id=hub-1&n=Studio%20Mac');

  group('invite', () {
    test('parses v2 and the Companion v1 code', () {
      final v2 = invite();
      expect(v2.version, 2);
      expect(v2.hubID, 'hub-1');
      expect(v2.hubName, 'Studio Mac');
      final v1 = HubInvite.parse('artblend-companion://pair?v=1&u=https%3A%2F%2F10.0.0.2%3A8765&fp=${'AB:' * 31}AB&c=999999');
      expect(v1.version, 1);
      expect(v1.fingerprint, 'ab' * 32);
    });

    test('rejects malformed codes', () {
      for (final raw in [
        'https://evil.example/pair?v=2',
        'localhub://pair?v=1&u=https%3A%2F%2Fa%3A1&fp=${'ab' * 32}&c=123456',
        'localhub://pair?v=2&u=http%3A%2F%2Fa%3A1&fp=${'ab' * 32}&c=123456',
        'localhub://pair?v=2&u=https%3A%2F%2Fa%3A1%2Fx&fp=${'ab' * 32}&c=123456',
        'localhub://pair?v=2&u=https%3A%2F%2Fa%3A1&fp=abcd&c=123456',
        'localhub://pair?v=2&u=https%3A%2F%2Fa%3A1&fp=${'ab' * 32}&c=12345',
        'localhub://pair?v=2&u=https%3A%2F%2Fa%3A1&fp=${'ab' * 32}&c=123456&c=654321',
      ]) {
        expect(() => HubInvite.parse(raw), throwsFormatException, reason: raw);
      }
    });
  });

  test('pairs, stores the session and uses the pinned connection', () async {
    final store = MemorySessionStore();
    final client = HubClient(store);
    final session = await client.pair(invite(), deviceName: 'MatePad', app: 'artblend');
    expect(session.token, token);
    expect(session.scopes, ['chat', 'image.edit']);
    expect((await store.load())?.deviceID, 'dev-1');
    expect(jsonDecode(requests.last.body), {'code': '123456', 'deviceName': 'MatePad', 'app': 'artblend'});

    final restored = HubClient(store);
    await restored.restore();
    expect((await restored.models()).single['id'], 'lmstudio/qwen');
    expect((await restored.integrations()).single['state'], 'running', reason: '/v2 lists are bare arrays');
    expect(requests.last.authorization, 'Bearer $token');
  });

  test('a wrong pin fails before any request reaches the hub', () async {
    final before = requests.length;
    final client = HubClient(MemorySessionStore());
    await expectLater(client.pair(invite(fp: '00' * 32), deviceName: 'x', app: 'artblend'), throwsA(isA<HandshakeException>()));
    expect(requests.length, before);
  });

  test('typed errors, streaming chat and unpairing', () async {
    final store = MemorySessionStore();
    final client = HubClient(store);
    await expectLater(client.pair(invite(code: '000000'), deviceName: 'x', app: 'artblend'),
        throwsA(isA<HubException>().having((e) => e.code, 'code', 'wrong_code')));
    await client.pair(invite(), deviceName: 'x', app: 'artblend');
    await expectLater(client.chat({'model': 'ollama/llama3', 'messages': []}),
        throwsA(isA<HubException>().having((e) => e.status, 'status', 503).having((e) => e.provider, 'provider', 'ollama')));

    final text = await client.chatStream({'model': 'lmstudio/qwen', 'messages': []})
        .map((chunk) => (((chunk['choices'] as List).first as Map)['delta'] as Map)['content'] as String)
        .join();
    expect(text, 'Merhaba');
    expect(jsonDecode(requests.last.body)['stream'], true);

    await client.unpair();
    expect(requests.last.method, 'DELETE');
    expect(await store.load(), isNull);
    expect(() => client.models(), throwsStateError);
  });

  test('image edits upload multipart and jobs stream their progress', () async {
    final client = HubClient(MemorySessionStore());
    await client.pair(invite(), deviceName: 'x', app: 'artblend');
    expect((await client.workProfiles()).single['steps'], 4);
    final result = await client.editImage({'prompt': 'add a hat', 'strength': 0.6, 'profile': 'draft'}, image: HubInput.bytes(png, filename: 'canvas.png'));
    expect(base64.decode(((result['data'] as List).first as Map)['b64_json'] as String), png);
    expect(requests.last.contentType, startsWith('multipart/form-data; boundary=localhub-'));
    expect(requests.last.body, contains('name="prompt"\r\n\r\nadd a hat\r\n'));
    expect(requests.last.body, contains('name="profile"\r\n\r\ndraft\r\n'));
    expect(requests.last.body, contains('name="image"; filename="canvas.png"\r\nContent-Type: image/png'));
    expect(await client.fileContent('file-1'), png);

    final states = await client.jobEvents('job-1').map((job) => '${job['status']}').toList();
    expect(states, ['in_progress', 'completed']);
    expect((await client.recipe('job-1'))['workflowName'], 'SDXL');
    expect((await client.replayJob('job-1', variation: true))['variation'], true);
  });

  test('embeddings, transcription, previews and the device event stream', () async {
    final client = HubClient(MemorySessionStore());
    await client.pair(invite(), deviceName: 'x', app: 'artblend');
    expect(await client.embeddings('lmstudio/nomic', ['a fox']), [[0.1, 0.2]]);
    expect(await client.transcribe(Uint8List.fromList([1, 2]), language: 'tr'), 'merhaba dünya');
    expect(requests.last.body, contains('name="language"\r\n\r\ntr'));
    expect(utf8.decode((await client.jobPreview('job-1'))!), 'jpeg');
    expect(await client.jobPreview('job-2'), isNull);
    final events = await client.deviceEvents().map((e) => e.type == 'job' ? 'job:${e.data['current_node']}' : e.type).toList();
    expect(events, ['job:KSampler 3/20', 'session', 'revoked']);
  });

  test('MCP servers, tools and calls with typed errors', () async {
    final client = HubClient(MemorySessionStore());
    await client.pair(invite(), deviceName: 'x', app: 'artblend');
    expect((await client.mcpServers()).single['allowedTools'], ['echo']);
    final tools = await client.mcpTools('my tools');
    expect(requests.last.path, '/v2/mcp/my%20tools/tools', reason: 'server id is one encoded path segment');
    expect(tools.single['name'], 'echo');
    final result = await client.mcpCall('my tools', 'echo', {'text': 'merhaba'});
    expect(jsonDecode(requests.last.body), {'name': 'echo', 'arguments': {'text': 'merhaba'}});
    expect(((result['content'] as List).single as Map)['text'], 'merhaba');
    expect(result['isError'], false);
    await expectLater(client.mcpCall('my tools', 'rm', {'path': '/'}),
        throwsA(isA<HubException>().having((e) => e.status, 'status', 403).having((e) => e.code, 'code', 'forbidden')));
    await expectLater(client.mcpCall('my tools', 'echo', {}),
        throwsA(isA<HubException>().having((e) => e.status, 'status', 400).having((e) => e.code, 'code', 'bad_request')));
  });
}
