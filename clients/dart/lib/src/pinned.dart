import 'dart:io';

import 'package:crypto/crypto.dart';

import 'invite.dart';

/// An [HttpClient] that trusts exactly one certificate: the one whose SHA-256
/// matches [fingerprint], served from [address]'s host and port, in date.
/// No CA is trusted, so the callback decides every connection before any
/// request bytes (or the bearer token) are written.
HttpClient pinnedHttpClient(Uri address, String fingerprint) {
  final expected = normalizeFingerprint(fingerprint);
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = const Duration(seconds: 10);
  client.badCertificateCallback = (certificate, host, port) {
    final now = DateTime.now();
    return host == address.host &&
        port == address.port &&
        certificate.startValidity.isBefore(now) &&
        certificate.endValidity.isAfter(now) &&
        sha256.convert(certificate.der).toString() == expected;
  };
  return client;
}
