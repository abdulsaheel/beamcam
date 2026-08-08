import 'dart:convert';

/// Port the desktop receiver listens on. The phone reaches it either over the
/// LAN directly, or via `adb reverse tcp:8787 tcp:8787` at 127.0.0.1 — the
/// latter needs no IP typed on a phone keyboard and survives flaky Wi-Fi AP
/// isolation.
const int kSignalPort = 8787;
const String kSignalPath = '/ws';

/// Empty on purpose: both peers sit on the same LAN, so host candidates pair
/// immediately. Adding a STUN server here only delays ICE gathering.
const Map<String, dynamic> kRtcConfig = {
  'iceServers': <Map<String, dynamic>>[],
  'sdpSemantics': 'unified-plan',
};

/// Wire format for the signaling channel. Deliberately tiny — offer, answer,
/// ICE trickle, and a liveness ping.
class Signal {
  const Signal(this.type, [this.data = const {}]);

  final String type;
  final Map<String, dynamic> data;

  static Signal decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return Signal(
      map['type'] as String,
      (map['data'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  String encode() => jsonEncode({'type': type, 'data': data});

  @override
  String toString() => 'Signal($type)';
}
