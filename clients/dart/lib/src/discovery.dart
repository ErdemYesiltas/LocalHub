import 'package:multicast_dns/multicast_dns.dart';

import 'invite.dart';

class DiscoveredHub {
  const DiscoveredHub({required this.id, required this.name, required this.fingerprint, required this.host, required this.port});

  /// The hub's stable id (same as the invite's `id`).
  final String id;
  final String name;

  /// Advertised fingerprint; only used to pick the right hub. Trust stays with the pin you stored.
  final String fingerprint;
  final String host;
  final int port;
}

/// Finds LocalHub instances on the local network via Bonjour (`_localhub._tcp`).
Future<List<DiscoveredHub>> discoverHubs({Duration timeout = const Duration(seconds: 2)}) async {
  const service = '_localhub._tcp.local';
  final client = MDnsClient();
  final hubs = <DiscoveredHub>[];
  await client.start();
  try {
    await for (final pointer in client.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(service), timeout: timeout)) {
      final txt = <String, String>{};
      await for (final record in client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(pointer.domainName), timeout: timeout)) {
        for (final line in record.text.split('\n')) {
          final split = line.indexOf('=');
          if (split > 0) txt[line.substring(0, split)] = line.substring(split + 1);
        }
      }
      await for (final srv in client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(pointer.domainName), timeout: timeout)) {
        await for (final address in client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target), timeout: timeout)) {
          final id = txt['id'];
          final fp = txt['fp'];
          if (txt['v'] != '2' || id == null || fp == null) continue;
          try {
            hubs.add(DiscoveredHub(id: id, name: txt['n'] ?? pointer.domainName, fingerprint: normalizeFingerprint(fp),
                host: address.address.address, port: srv.port));
          } on FormatException {
            continue;
          }
          break;
        }
      }
    }
  } finally {
    client.stop();
  }
  final unique = <String, DiscoveredHub>{};
  for (final hub in hubs) {
    unique.putIfAbsent(hub.id, () => hub);
  }
  return unique.values.toList();
}
