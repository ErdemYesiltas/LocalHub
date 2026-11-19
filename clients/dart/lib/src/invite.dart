/// What the hub's QR carries: the same values a user could type. Scanning grants
/// no more trust than typing them; the fingerprint is the only trust anchor.
class HubInvite {
  const HubInvite({
    required this.address,
    required this.fingerprint,
    required this.code,
    required this.version,
    this.hubID,
    this.hubName,
  });

  final Uri address;
  final String fingerprint;
  final String code;
  final int version;
  final String? hubID;
  final String? hubName;

  /// v2: `localhub://pair?v=2&u=<https url>&fp=<sha256>&c=<6 digits>&id=<hub id>&n=<name>`
  /// v1: `artblend-companion://pair?v=1&u=…&fp=…&c=…` (ArtBlend Companion)
  factory HubInvite.parse(String raw) {
    final text = raw.trim();
    final uri = text.length > 1024 ? null : Uri.tryParse(text);
    if (uri == null ||
        !(uri.scheme == 'localhub' || uri.scheme == 'artblend-companion') ||
        uri.host != 'pair' ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('Not a LocalHub pairing code');
    }
    final query = uri.queryParametersAll;
    String? single(String key, {bool required = true}) {
      final values = query[key];
      if ((values?.length ?? 0) > 1 || (required && values == null)) {
        throw const FormatException('Incomplete pairing code');
      }
      return values?.single;
    }

    final version = single('v');
    final v2 = uri.scheme == 'localhub' && version == '2';
    final v1 = uri.scheme == 'artblend-companion' && version == '1';
    if (!v1 && !v2) throw const FormatException('Unsupported pairing code version');
    final code = single('c')!;
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const FormatException('Invalid pairing code in QR');
    }
    final id = v2 ? single('id', required: false) : null;
    final name = v2 ? single('n', required: false) : null;
    return HubInvite(
      address: hubAddress(single('u')!),
      fingerprint: normalizeFingerprint(single('fp')!),
      code: code,
      version: v2 ? 2 : 1,
      hubID: id != null && RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(id) ? id : null,
      hubName: name == null ? null : (name.length > 40 ? name.substring(0, 40) : name),
    );
  }
}

String normalizeFingerprint(String value) {
  final normalized = value.replaceAll(RegExp(r'[:\s]'), '').toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    throw const FormatException('Expected a SHA-256 certificate fingerprint');
  }
  return normalized;
}

Uri hubAddress(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('Enter an HTTPS hub address without a path or credentials');
  }
  return uri.replace(path: '');
}
