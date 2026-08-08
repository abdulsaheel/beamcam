import 'package:shared_preferences/shared_preferences.dart';

import 'pairing.dart';

/// Remembers Macs the phone has paired with, so opening the app reconnects
/// without discovery, scanning, or typing.
///
/// This is what actually makes repeat use feel instant — discovery is only
/// needed the first time, or when the saved address goes stale.
class PairingStore {
  static const _kKnown = 'beamcam.known_macs';
  static const _kLast = 'beamcam.last_mac';

  /// Most recent first, capped so a phone that hops networks does not grow an
  /// unbounded list of dead addresses.
  static const int maxRemembered = 8;

  Future<List<PairingPayload>> known() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKnown);
    // Growable, never const: callers mutate this list, and a const [] here
    // throws "Cannot remove from an unmodifiable list" on the very first pairing.
    return raw == null ? <PairingPayload>[] : PairingPayload.decodeList(raw);
  }

  Future<PairingPayload?> last() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLast);
    if (raw == null) return null;
    return PairingPayload.tryParse(raw);
  }

  /// Records a successful pairing. Re-saving a known Mac moves it to the front
  /// rather than duplicating it — equality is host+port, so a renamed Mac at
  /// the same address updates in place.
  Future<void> remember(PairingPayload payload) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await known();
    list.removeWhere((e) => e == payload);
    list.insert(0, payload);

    await prefs.setString(
      _kKnown,
      PairingPayload.encodeList(list.take(maxRemembered).toList()),
    );
    await prefs.setString(_kLast, payload.encode());
  }

  Future<void> forget(PairingPayload payload) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await known();
    list.removeWhere((e) => e == payload);
    await prefs.setString(_kKnown, PairingPayload.encodeList(list));

    final lastOne = await last();
    if (lastOne == payload) await prefs.remove(_kLast);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKnown);
    await prefs.remove(_kLast);
  }
}
