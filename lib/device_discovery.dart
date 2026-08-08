import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

import 'pairing.dart';
import 'signaling.dart';

/// Browses the local network for desktops advertising BeamCam over Bonjour.
///
/// Lifted wholesale from the old pushed pairing screen — the browse logic was
/// never the problem, its location was. Owning it here lets the home screen be
/// the device list, which is the whole point of the rework.
class DeviceDiscovery extends ChangeNotifier {
  nsd.Discovery? _discovery;
  Timer? _settleTimer;
  bool _disposed = false;
  bool _blocked = false;
  bool _settled = false;
  List<PairingPayload> _devices = const [];

  /// Everything currently answering on this network, freshest resolve wins.
  List<PairingPayload> get devices => _devices;

  /// True once we have browsed long enough that "nothing here" is a real answer
  /// rather than an unfinished one. Before this, the UI shows a spinner; after,
  /// it offers the QR and typed-address routes instead of spinning forever.
  bool get settled => _settled || _blocked;

  /// The platform refused to browse at all. Multicast is blocked on plenty of
  /// corporate and guest networks — not a failure worth shouting about, just a
  /// reason to lead with the other two routes.
  bool get blocked => _blocked;

  bool get searching => _discovery != null && !_settled;

  Future<void> start() async {
    if (_discovery != null || _disposed) return;
    _blocked = false;
    _settled = false;
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(seconds: 6), () {
      _settled = true;
      _notify();
    });
    _notify();

    try {
      final discovery = await nsd.startDiscovery(
        kServiceType,
        autoResolve: true,
      );
      if (_disposed) {
        unawaited(nsd.stopDiscovery(discovery).catchError((_) {}));
        return;
      }
      _discovery = discovery;
      discovery.addListener(_onDiscoveryChanged);
      _onDiscoveryChanged();
    } catch (e) {
      debugPrint('BeamCam: discovery unavailable — $e');
      _blocked = true;
      _settleTimer?.cancel();
      _notify();
    }
  }

  Future<void> restart() async {
    await stop();
    _devices = const [];
    _notify();
    await start();
  }

  Future<void> stop() async {
    _settleTimer?.cancel();
    _settleTimer = null;
    final discovery = _discovery;
    _discovery = null;
    if (discovery == null) return;
    discovery.removeListener(_onDiscoveryChanged);
    try {
      await nsd.stopDiscovery(discovery);
    } catch (_) {
      // Already gone, or the platform never really started it.
    }
  }

  void _onDiscoveryChanged() {
    final discovery = _discovery;
    if (discovery == null) return;

    final found = <PairingPayload>[];
    for (final service in discovery.services) {
      final resolved = service.addresses?.first.address ?? service.host;
      if (resolved == null || resolved.isEmpty) continue;
      // Bonjour hands back fully-qualified names carrying the root label —
      // "studio-pc.local." — which is legal DNS, ugly on screen, and rejected
      // by some resolvers. It comes off once, here, rather than at every call
      // site that shows or dials a host.
      final host = resolved.endsWith('.')
          ? resolved.substring(0, resolved.length - 1)
          : resolved;
      found.add(
        PairingPayload(
          host: host,
          port: service.port ?? kSignalPort,
          name: service.name ?? '',
        ),
      );
    }

    _devices = found;
    // Something answered, so there is nothing left to wait for.
    if (found.isNotEmpty) {
      _settled = true;
      _settleTimer?.cancel();
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _settleTimer?.cancel();
    unawaited(stop());
    super.dispose();
  }
}
