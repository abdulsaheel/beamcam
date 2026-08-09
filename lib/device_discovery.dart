import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

import 'pairing.dart';
import 'signaling.dart';

/// Browses the local network for desktops advertising BeamCam over Bonjour.
class DeviceDiscovery extends ChangeNotifier {
  nsd.Discovery? _discovery;
  bool _disposed = false;
  List<PairingPayload> _devices = const [];

  List<PairingPayload> get devices => _devices;

  Future<void> start() async {
    if (_discovery != null || _disposed) return;

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
    final discovery = _discovery;
    _discovery = null;
    if (discovery == null) return;
    discovery.removeListener(_onDiscoveryChanged);
    try {
      await nsd.stopDiscovery(discovery);
    } catch (_) {
    }
  }

  void _onDiscoveryChanged() {
    final discovery = _discovery;
    if (discovery == null) return;

    final found = <PairingPayload>[];
    for (final service in discovery.services) {
      final resolved = service.addresses?.first.address ?? service.host;
      if (resolved == null || resolved.isEmpty) continue;
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
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
