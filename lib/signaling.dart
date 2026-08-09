import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';


const int kSignalPort = 8787;
const String kSignalPath = '/ws';

const Map<String, dynamic> kRtcConfig = {
  'iceServers': <Map<String, dynamic>>[],
  'sdpSemantics': 'unified-plan',
};

/// Signaling wire format: offer, answer, ice, transform.
class Signal {
  const Signal(this.type, [this.data = const {}]);

  factory Signal.ice(RTCIceCandidate c) => Signal('ice', {
    'candidate': c.candidate,
    'sdpMid': c.sdpMid,
    'sdpMLineIndex': c.sdpMLineIndex,
  });

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

  RTCIceCandidate toCandidate() => RTCIceCandidate(
    data['candidate'] as String?,
    data['sdpMid'] as String?,
    data['sdpMLineIndex'] as int?,
  );
}
