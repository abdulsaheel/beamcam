import 'signaling.dart';

/// Bonjour service type the Mac advertises and the phone browses for. The
/// underscore-prefixed pair is required by the mDNS spec, not decoration.
const String kServiceType = '_beamcam._tcp';

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

  String encode() => Uri(
    scheme: scheme,
    host: 'connect',
    queryParameters: {'h': host, 'p': '$port', 'n': name},
  ).toString();

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

  @override
  bool operator ==(Object other) =>
      other is PairingPayload && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}
