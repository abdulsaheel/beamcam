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

/// Bridge to the native side that installs and reports on the virtual
/// microphone driver. Separate install lifecycle from the camera extension:
/// a HAL driver copy + coreaudiod restart, not an OSSystemExtensionRequest.
const _audioDriverChannel = MethodChannel('beamcam/audiodriver');

/// Bridge that pumps the remote track's frames into the extension's sink stream.
const _sinkChannel = MethodChannel('beamcam/sink');

/// Bridge that pumps the remote audio track's PCM into the virtual mic driver.
/// Separate channel from `beamcam/sink`: video and audio are two independent
/// pipelines (extension vs. HAL driver) that can each be live without the
/// other, so they get their own start/stop/status rather than overloading one.
const _audioSinkChannel = MethodChannel('beamcam/audiosink');

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
  bool _hasAudio = false;
  String _extensionStatus = 'idle';
  String _sinkStatus = 'idle';
  String _audioSinkStatus = 'idle';
  String _audioDriverStatus = 'idle';

  bool get _hasMedia => _hasVideo || _hasAudio;

  bool get _audioDriverReady => _audioDriverStatus.startsWith('installed');

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
    _audioDriverChannelSetup();
    _sinkChannelSetup();
    _boot();
  }

  void _audioDriverChannelSetup() {
    _audioDriverChannel.setMethodCallHandler((call) async {
      if (call.method == 'status' && mounted) {
        setState(() => _audioDriverStatus = call.arguments as String);
      }
      return null;
    });
    _audioDriverChannel
        .invokeMethod<String>('status')
        .then((s) {
          if (s != null && mounted) setState(() => _audioDriverStatus = s);
        })
        .catchError((_) {});
  }

  void _sinkChannelSetup() {
    _sinkChannel.setMethodCallHandler((call) async {
      if (call.method == 'status' && mounted) {
        setState(() => _sinkStatus = call.arguments as String);
      }
      return null;
    });
    _audioSinkChannel.setMethodCallHandler((call) async {
      if (call.method == 'status' && mounted) {
        setState(() => _audioSinkStatus = call.arguments as String);
      }
      return null;
    });
  }

  /// Same retry shape as _startSink: the plugin registers the remote track
  /// slightly after Dart sees onTrack.
  Future<void> _startAudioSink(String trackId) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final ok = await _audioSinkChannel.invokeMethod<bool>('startAudioSink', {
          'trackId': trackId,
        });
        if (ok ?? false) return;
      } on PlatformException catch (e) {
        if (mounted) setState(() => _audioSinkStatus = 'error: ${e.message}');
        return;
      } on MissingPluginException {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (mounted) setState(() => _audioSinkStatus = 'track not found');
  }

  void _stopAudioSink() {
    _audioSinkChannel.invokeMethod('stopAudioSink').catchError((_) {});
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
      if (event.streams.isEmpty) return;
      if (event.track.kind == 'video') {
        _remoteStream = event.streams.first;
        if (_showPreview) _renderer.srcObject = _remoteStream;
        if (mounted) setState(() => _hasVideo = true);
        _startSink(event.track.id!);
      } else if (event.track.kind == 'audio') {
        if (mounted) setState(() => _hasAudio = true);
        _startAudioSink(event.track.id!);
      }
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
    // Negotiated unconditionally, independent of the video transceiver above:
    // the phone may connect with camera only, mic only, or both. An unused
    // RecvOnly transceiver costs nothing; onTrack only fires — and only then
    // does the audio sink start — once a real track shows up on it.
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
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
    _stopAudioSink();
    _remoteStream = null;
    _socket?.close();
    _socket = null;
    _pc?.close();
    _pc = null;
    _renderer.srcObject = null;
    if (mounted) setState(() { _hasVideo = false; _hasAudio = false; });
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
      body: _hasMedia ? _liveBody(context) : _waitingBody(context),
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
                    if (_hasVideo) ...[
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        leading: const Icon(Icons.cable),
                        title: const Text('Virtual camera'),
                        subtitle: Text(_sinkStatus),
                      ),
                    ],
                    if (_hasAudio) ...[
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        leading: const Icon(Icons.mic_outlined),
                        title: const Text('Virtual microphone'),
                        subtitle: Text(_audioSinkStatus),
                      ),
                    ],
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
              _InstallCard(
                icon: Icons.videocam_outlined,
                title: 'Virtual camera',
                explanation:
                    'Required so your phone shows up as a camera in Zoom, '
                    'Meet, and other apps.',
                ready: _extensionReady,
                status: _extensionStatus,
                buttonLabel: 'Install virtual camera',
                onInstall: () => _extensionChannel.invokeMethod('install'),
              ),
              const SizedBox(height: 16),
              _InstallCard(
                icon: Icons.mic_none_outlined,
                title: 'Virtual microphone',
                explanation:
                    'Required so your phone\'s mic shows up as a microphone '
                    'in Zoom, Discord, and other apps. Needs your Mac '
                    'password once to install.',
                ready: _audioDriverReady,
                status: _audioDriverStatus,
                buttonLabel: 'Install virtual microphone',
                onInstall: () => _audioDriverChannel.invokeMethod('install'),
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

/// A required-setup step: what it's for, whether it's done, and a button to
/// do it when it isn't — so it's obvious this has to happen before the
/// virtual camera/mic will actually show up anywhere else on the Mac.
class _InstallCard extends StatelessWidget {
  const _InstallCard({
    required this.icon,
    required this.title,
    required this.explanation,
    required this.ready,
    required this.status,
    required this.buttonLabel,
    required this.onInstall,
  });

  final IconData icon;
  final String title;
  final String explanation;
  final bool ready;
  final String status;
  final String buttonLabel;
  final VoidCallback onInstall;

  /// Raw statuses ("idle", "requesting admin authorization…", "error: …")
  /// are developer-facing; only surface the ones that tell the user
  /// something is actively happening or went wrong.
  String? get _statusLine {
    if (ready) return null;
    if (status == 'idle') return null;
    return status;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                ),
                if (ready)
                  const Icon(Icons.check_circle, color: Colors.green, size: 20)
                else
                  Icon(Icons.error_outline,
                      color: Theme.of(context).colorScheme.error, size: 20),
              ],
            ),
            const SizedBox(height: 6),
            Text(explanation, style: Theme.of(context).textTheme.bodySmall),
            if (_statusLine case final line?) ...[
              const SizedBox(height: 4),
              Text(line,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontStyle: FontStyle.italic)),
            ],
            if (!ready) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  onPressed: onInstall,
                  child: Text(buttonLabel),
                ),
              ),
            ],
          ],
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
