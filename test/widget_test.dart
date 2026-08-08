import 'package:beamcam/signaling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Signal', () {
    test('round-trips an offer through the wire format', () {
      const original = Signal('offer', {'sdp': 'v=0...', 'sdpType': 'offer'});
      final decoded = Signal.decode(original.encode());

      expect(decoded.type, 'offer');
      expect(decoded.data['sdp'], 'v=0...');
      expect(decoded.data['sdpType'], 'offer');
    });

    test('tolerates a payload with no data field', () {
      final decoded = Signal.decode('{"type":"ping"}');

      expect(decoded.type, 'ping');
      expect(decoded.data, isEmpty);
    });

    test('preserves a null sdpMid in an ICE candidate', () {
      const candidate = Signal('ice', {
        'candidate': 'candidate:1 1 udp 2130706431 192.168.1.3 54321 typ host',
        'sdpMid': null,
        'sdpMLineIndex': 0,
      });
      final decoded = Signal.decode(candidate.encode());

      expect(decoded.data['sdpMid'], isNull);
      expect(decoded.data['sdpMLineIndex'], 0);
    });
  });
}
