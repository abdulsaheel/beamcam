import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:qr_flutter/qr_flutter.dart';

import 'about.dart';
import 'main.dart';
import 'pairing.dart';
import 'signaling.dart';

/// Bridge to the native side that installs and reports on the camera extension.
const _extensionChannel = MethodChannel('beamcam/extension');

/// Bridge that pumps the remote track's frames into the extension's sink stream.
const _sinkChannel = MethodChannel('beamcam/sink');

class ReceiverPage extends StatefulWidget {
  const ReceiverPage({super.key});

  @override
  State<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends State<ReceiverPage> {
  final _renderer = RTCVideoRenderer();

  HttpServer? _server;
  WebSocket? _socket;
  RTCPeerConnection? _pc;

  String _status = 'Starting…';
  bool _hasVideo = false;
  String _extensionStatus = 'idle';
  String _sinkStatus = 'idle';

  /// Off by default: the native bridge feeds the extension directly, so
  /// rendering a second copy costs GPU for nothing.
  bool _showPreview = false;
  bool _mirror = false;
  bool _flip = false;
  MediaStream? _remoteStream;

  nsd.Registration? _registration;
  PairingPayload? _payload;

  /// Once macOS reports the extension installed there is nothing left to do,
  /// so the button retires rather than inviting a pointless reinstall.
  bool get _extensionReady => _extensionStatus.startsWith('installed');

  @override
  void initState() {
    super.initState();
    _extensionChannelSetup();
    _sinkChannelSetup();
    _boot();
  }

  void _sinkChannelSetup() {
    _sinkChannel.setMethodCallHandler((call) async {
      if (call.method == 'status' && mounted) {
        setState(() => _sinkStatus = call.arguments as String);
      }
      return null;
    });
  }

  /// The plugin registers a remote track slightly after Dart sees onTrack, so
  /// a miss here is normal on the first try rather than a hard failure.
  Future<void> _startSink(String trackId) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final ok = await _sinkChannel.invokeMethod<bool>('startSink', {
          'trackId': trackId,
        });
        if (ok ?? false) return;
      } on PlatformException catch (e) {
        if (mounted) setState(() => _sinkStatus = 'error: ${e.message}');
        return;
      } on MissingPluginException {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (mounted) setState(() => _sinkStatus = 'track not found');
  }

  void _stopSink() {
    _sinkChannel.invokeMethod('stopSink').catchError((_) {});
  }

  void _setShowPreview(bool show) {
    setState(() {
      _showPreview = show;
      _renderer.srcObject = show ? _remoteStream : null;
    });
  }

  void _extensionChannelSetup() {
    _extensionChannel.setMethodCallHandler((call) async {
      if (call.method == 'status' && mounted) {
        setState(() => _extensionStatus = call.arguments as String);
      }
      return null;
    });
    _extensionChannel
        .invokeMethod<String>('status')
        .then((s) {
          if (s != null && mounted) setState(() => _extensionStatus = s);
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _dropPeer();
    final registration = _registration;
    if (registration != null) nsd.unregister(registration);
    _server?.close(force: true);
    _renderer.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await _renderer.initialize();
    final host = await _listAddresses();
    await _serve();
    await _publish(host);
  }

  /// Announces this Mac two ways at once. Bonjour covers the common case where
  /// the phone can just find it; the QR carries the same payload for networks
  /// that block multicast, where discovery silently returns nothing.
  Future<void> _publish(String? host) async {
    if (host == null) return;

    final name = Platform.localHostname.replaceAll('.local', '');
    final payload = PairingPayload(host: host, port: kSignalPort, name: name);
    if (mounted) setState(() => _payload = payload);
    _sinkChannel
        .invokeMethod('setPairing', {'uri': payload.encode()})
        .catchError((_) {});

    try {
      _registration = await nsd.register(
        nsd.Service(name: name, type: kServiceType, port: kSignalPort),
      );
    } catch (e) {
      // Discovery is a convenience, not a dependency — the QR and manual entry
      // still work, so this must never take the receiver down.
      debugPrint('BeamCam: mDNS registration failed: $e');
    }
  }

  Future<String?> _listAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final i in interfaces) {
      for (final a in i.addresses) {
        return a.address;
      }
    }
    return null;
  }

  Future<void> _serve() async {
    try {
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        kSignalPort,
      );
      _server = server;
      _set('Waiting for a phone on port $kSignalPort');

      server.listen((request) async {
        if (request.uri.path != kSignalPath ||
            !WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        _attach(socket);
      });
    } on SocketException catch (e) {

      _set('Cannot bind port $kSignalPort — $e');
    }
  }

  void _set(String msg) {
    if (mounted) setState(() => _status = msg);
  }

  void _attach(WebSocket socket) {
    // One phone at a time; a second connection replaces the first.
    _dropPeer();
    _socket = socket;
    _set('Phone connected, negotiating…');

    socket.listen(
      (raw) => _onSignal(socket, Signal.decode(raw as String)),
      onDone: () {
        _dropPeer();
        _set('Phone disconnected. Waiting on port $kSignalPort');
      },
      onError: (e) => _set('Signaling error: $e'),
    );
  }

  Future<void> _onSignal(WebSocket socket, Signal signal) async {
    switch (signal.type) {
      case 'offer':
        await _answer(socket, signal);
      case 'transform':
        final mirror = signal.data['mirror'] ?? false;
        final flip = signal.data['flip'] ?? false;
        if (mounted) setState(() { _mirror = mirror; _flip = flip; });
        await _sinkChannel
            .invokeMethod('setTransform', {'mirror': mirror, 'flip': flip})
            .catchError((_) {});
      case 'ice':
        await _pc?.addCandidate(signal.toCandidate());
      default:
        break;
    }
  }

  Future<void> _answer(WebSocket socket, Signal offer) async {
    final pc = await createPeerConnection(kRtcConfig);
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      socket.add(Signal.ice(candidate).encode());
    };

    pc.onTrack = (event) {
      if (event.track.kind != 'video' || event.streams.isEmpty) return;
      _remoteStream = event.streams.first;
      if (_showPreview) _renderer.srcObject = _remoteStream;
      if (mounted) setState(() => _hasVideo = true);
      _startSink(event.track.id!);
    };

    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _set('Live');
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _set('Media path failed — are both devices on the same subnet?');
      }
    };

    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    await pc.setRemoteDescription(
      RTCSessionDescription(
        offer.data['sdp'] as String,
        offer.data['sdpType'] as String,
      ),
    );

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    socket.add(
      Signal('answer', {'sdp': answer.sdp, 'sdpType': answer.type}).encode(),
    );
  }

  void _dropPeer() {
    _stopSink();
    _remoteStream = null;
    _socket?.close();
    _socket = null;
    _pc?.close();
    _pc = null;
    _renderer.srcObject = null;
    if (mounted) setState(() => _hasVideo = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BeamCam'),
        actions: [
          if (_hasVideo)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  const Text('Preview'),
                  Switch(value: _showPreview, onChanged: _setShowPreview),
                ],
              ),
            ),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (context, mode, _) => PopupMenuButton<ThemeMode>(
              icon: Icon(mode.icon),
              tooltip: 'Appearance',
              initialValue: mode,
              onSelected: (m) => unawaited(setThemeMode(m)),
              itemBuilder: (context) => [
                for (final m in ThemeMode.values)
                  PopupMenuItem(
                    value: m,
                    child: Row(
                      children: [
                        Icon(m.icon, size: 18),
                        const SizedBox(width: 12),
                        Text(m.label),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About',
            onPressed: () => unawaited(showAboutSheet(context)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _hasVideo ? _liveBody(context) : _waitingBody(context),
    );
  }

  Widget _liveBody(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showPreview) ...[
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(19),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ColoredBox(
                        color: Colors.black,
                        child: Transform.scale(
                          scaleX: _mirror ? -1 : 1,
                          scaleY: _flip ? -1 : 1,
                          child: RTCVideoView(
                            _renderer,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitContain,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        Icons.videocam,
                        color: theme.colorScheme.primary,
                      ),
                      title: const Text('BeamCam is live'),
                      subtitle: Text(_status),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.tv_outlined),
                      title: const Text('Pick "BeamCam" as the camera'),
                      subtitle: const Text(
                        'It appears anywhere a webcam does — Meet, Zoom, '
                        'FaceTime, your browser.',
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.cable),
                      title: const Text('Virtual camera'),
                      subtitle: Text(_sinkStatus),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _waitingBody(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PairingCard(payload: _payload, status: _status),
              const SizedBox(height: 20),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.videocam_outlined),
                      title: const Text('Virtual camera'),
                      subtitle: Text(_extensionStatus),
                    ),
                    if (!_extensionReady)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.tonal(
                            onPressed: () =>
                                _extensionChannel.invokeMethod('install'),
                            child: const Text('Install virtual camera'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              const AboutFooter(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pairing code and the address behind it.
class _PairingCard extends StatelessWidget {
  const _PairingCard({required this.payload, required this.status});

  final PairingPayload? payload;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            Text('Connect your phone', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'Open BeamCam on your phone and pick this computer, or scan '
              'this code.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            if (payload == null)
              const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              // White plate regardless of theme: a QR on a dark surface will
              // not scan.
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: QrImageView(
                  data: payload!.encode(),
                  size: 168,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(height: 20),
              Text(payload!.name, style: theme.textTheme.titleMedium),
              SelectableText(
                '${payload!.host}:${payload!.port}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              status,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
