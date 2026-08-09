import 'package:shared_preferences/shared_preferences.dart';

import 'pairing.dart';

/// Remembers computers the phone has paired with, so opening the app
/// reconnects without discovery, scanning, or typing.
class PairingStore {
  /// Saved as pairing URIs — the same string the QR carries — so the app has
  /// one serialisation instead of two.
  static const _key = 'beamcam.saved';

  /// Most recent first, capped so a phone that hops networks does not grow an
  /// unbounded list of dead addresses.
  static const int maxRemembered = 8;

  Future<List<PairingPayload>> known() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const <String>[];
    // toList() is growable, which callers rely on.
    return raw.map(PairingPayload.tryParse).nonNulls.toList();
  }

  /// Records a successful pairing. Re-saving a known computer moves it to the
  /// front rather than duplicating it — equality is host+port, so a renamed
  /// machine at the same address updates in place.
  Future<void> remember(PairingPayload payload) async {
    final list = await known();
    list.removeWhere((e) => e == payload);
    list.insert(0, payload);
    await _write(list.take(maxRemembered).toList());
  }

  Future<void> forget(PairingPayload payload) async {
    final list = await known();
    list.removeWhere((e) => e == payload);
    await _write(list);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  Future<void> _write(List<PairingPayload> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, [for (final e in list) e.encode()]);
  }
}
