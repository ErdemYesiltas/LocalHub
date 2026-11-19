// Pair with a running hub from its invite (the text inside the QR) and list models.
//   dart run example/list_models.dart '<invite>'
import 'dart:io';

import 'package:localhub_client/localhub_client.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/list_models.dart <invite>');
    exit(2);
  }
  final client = HubClient(MemorySessionStore());
  final session = await client.pair(HubInvite.parse(args.first), deviceName: 'Dart example', app: 'example');
  print('paired with ${session.hubName ?? session.address} as ${session.deviceID}; scopes: ${session.scopes.join(', ')}');
  for (final integration in await client.integrations()) {
    print('integration ${integration['id']}: ${integration['state']}');
  }
  for (final model in await client.models()) {
    print('model ${model['id']} ${model['capabilities']}');
  }
  try {
    await client.chat({'model': 'ollama/llama3', 'messages': []});
  } on HubException catch (error) {
    print('ollama ${error.status} ${error.code}: ${error.message}');
  }
  await client.unpair();
  print('unpaired');
}
