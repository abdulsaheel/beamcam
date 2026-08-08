import 'dart:convert';

import 'signaling.dart';

/// Bonjour service type the Mac advertises and the phone browses for. The
/// underscore-prefixed pair is required by the mDNS spec, not decoration.
const String kServiceType = '_beamcam._tcp';

/// Everything the phone needs to reach a Mac, in one scannable string.
///
/// Encoded as a URI rather than JSON so a generic QR scanner shows something
/// meaningful, and so the payload survives being pasted into a text field:
///
///     beamcam://connect?h=192.168.1.4&p=8787&n=Abduls-Mac-mini
class PairingPayload {
  const PairingPayload({
    required this.host,
    this.port = kSignalPort,
    this.name = 'Mac',
  });

  final String host;
  final int port;
  final String name;

  static const String scheme = 'beamcam';

  Uri toUri() => Uri(
    scheme: scheme,
    host: 'connect',
    queryParameters: {'h': host, 'p': '$port', 'n': name},
  );

  String encode() => toUri().toString();

  /// Accepts a full pairing URI, or a bare host typed by hand ("192.168.1.4"
  /// or "192.168.1.4:8787"), so the scanner and the manual field can share one
  /// code path. Returns null when the input is not usable.
  static PairingPayload? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final uri = Uri.tryParse(text);
    if (uri != null && uri.scheme == scheme) {
      final host = uri.queryParameters['h'];
      if (host == null || host.isEmpty) return null;
      return PairingPayload(
        host: host,
        port: int.tryParse(uri.queryParameters['p'] ?? '') ?? kSignalPort,
        name: uri.queryParameters['n'] ?? 'Mac',
      );
    }

    // Bare "host" or "host:port".
    final parts = text.split(':');
    if (parts.length == 2) {
      final port = int.tryParse(parts[1]);
      if (port == null || !_looksLikeHost(parts[0])) return null;
      return PairingPayload(host: parts[0], port: port);
    }
    if (parts.length == 1 && _looksLikeHost(parts[0])) {
      return PairingPayload(host: parts[0]);
    }
    return null;
  }

  /// Deliberately permissive: hostnames and IPv4 both, rejecting only input
  /// that clearly cannot be an address.
  static bool _looksLikeHost(String value) =>
      value.isNotEmpty && RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value);

  Map<String, dynamic> toJson() => {'host': host, 'port': port, 'name': name};

  static PairingPayload fromJson(Map<String, dynamic> json) => PairingPayload(
    host: json['host'] as String,
    port: (json['port'] as num?)?.toInt() ?? kSignalPort,
    name: json['name'] as String? ?? 'Mac',
  );

  static String encodeList(List<PairingPayload> items) =>
      jsonEncode(items.map((e) => e.toJson()).toList());

  static List<PairingPayload> decodeList(String raw) {
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      // Growable for the same reason as PairingStore.known(): callers mutate it.
      return <PairingPayload>[];
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PairingPayload && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => '$name ($host:$port)';
}
