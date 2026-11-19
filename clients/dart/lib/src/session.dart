import 'invite.dart';

class HubSession {
  const HubSession({
    required this.address,
    required this.fingerprint,
    required this.token,
    required this.deviceID,
    required this.scopes,
    this.hubID,
    this.hubName,
  });

  final Uri address;
  final String fingerprint, token, deviceID;
  final List<String> scopes;
  final String? hubID, hubName;

  Map<String, Object?> toJson() => {
        'address': address.toString(),
        'fingerprint': fingerprint,
        'token': token,
        'deviceID': deviceID,
        'scopes': scopes,
        if (hubID != null) 'hubID': hubID,
        if (hubName != null) 'hubName': hubName,
      };

  factory HubSession.fromJson(Map<String, Object?> json) {
    final token = json['token'];
    final id = json['deviceID'];
    if (token is! String || token.length < 32 || token.length > 200 || id is! String || id.isEmpty) {
      throw const FormatException('Invalid LocalHub session');
    }
    return HubSession(
      address: hubAddress(json['address'] as String),
      fingerprint: normalizeFingerprint(json['fingerprint'] as String),
      token: token,
      deviceID: id,
      scopes: (json['scopes'] as List?)?.cast<String>() ?? const [],
      hubID: json['hubID'] as String?,
      hubName: json['hubName'] as String?,
    );
  }
}

/// Where the session (with its bearer token) lives. Flutter apps implement this
/// with `flutter_secure_storage`; never preferences or a plain file.
abstract interface class SessionStore {
  Future<HubSession?> load();
  Future<void> save(HubSession session);
  Future<void> clear();
}

class MemorySessionStore implements SessionStore {
  HubSession? _session;
  @override
  Future<HubSession?> load() async => _session;
  @override
  Future<void> save(HubSession session) async => _session = session;
  @override
  Future<void> clear() async => _session = null;
}
