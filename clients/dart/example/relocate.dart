// Pair, pretend the Mac's address changed, and let the client find the hub again via Bonjour.
//   dart run example/relocate.dart '<invite>'
import 'package:localhub_client/localhub_client.dart';

Future<void> main(List<String> args) async {
  final store = MemorySessionStore();
  final client = HubClient(store);
  final session = await client.pair(HubInvite.parse(args.first), deviceName: 'Dart relocate test', app: 'example');
  print('paired at ${session.address}');
  print('discovered: ${(await discoverHubs()).map((h) => '${h.name} ${h.host}:${h.port}').join(', ')}');
  await store.save(HubSession.fromJson({...session.toJson(), 'address': 'https://127.0.0.1:1'}));
  final moved = HubClient(store);
  await moved.restore();
  final models = await moved.models();
  print('models after relocate: ${models.length}; session now at ${moved.session!.address}');
  await moved.unpair();
}
