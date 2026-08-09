import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'connect_view.dart';
import 'pairing.dart';
import 'pairing_store.dart';
import 'signaling.dart';

enum LinkState {
  idle('Ready'),
  connecting('Connecting'),
  streaming('Live'),
  failed('Problem');

  const LinkState(this.label);

  final String label;
}

/// Android-only host channel: background service + rotation pinning.
const _serviceChannel = MethodChannel('beamcam/service');


enum Framing {
  landscape(
    'Landscape',
    'A wide frame, the shape calls expect',
    Icons.stay_current_landscape,
    [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
  ),
  portrait('Portrait', 'A tall frame', Icons.stay_current_portrait, [
    DeviceOrientation.portraitUp,
  ]),
  auto(
    'Auto',
    'Follows how you turn the phone',
    Icons.screen_rotation,
    DeviceOrientation.values,
  );

  const Framing(this.label, this.note, this.icon, this.orientations);

  final String label;
  final String note;
  final IconData icon;
  final List<DeviceOrientation> orientations;
}


enum Quality {
  sd('480p', 640, 480, 30, 1500000, 'Weak Wi‑Fi'),
  hd('720p', 1280, 720, 30, 4000000, 'Balanced'),
  fhd('1080p', 1920, 1080, 30, 8000000, 'Sharpest'),
  fhd60('1080p60', 1920, 1080, 60, 12000000, 'Smoothest motion');

  const Quality(
    this.label,
    this.w,
    this.h,
    this.fps,
    this.maxBitrate,
    this.note,
  );

  final String label;
  final int w;
  final int h;
  final int fps;

  /// Encoder ceiling in bits per second, applied to the sender after the track
  /// is added. WebRTC still ramps below this when the network says so.
  final int maxBitrate;
  final String note;

  String get spec =>
      '$w × $h · $fps fps · up to '
      '${(maxBitrate / 1e6).toStringAsFixed(maxBitrate % 1000000 == 0 ? 0 : 1)} Mbps';
}

class SenderPage extends StatefulWidget {
  const SenderPage({super.key});

  @override
  State<SenderPage> createState() => _SenderPageState();
}

class _SenderPageState extends State<SenderPage> {
  final _renderer = RTCVideoRenderer();
  final _store = PairingStore();
  final _appLinks = AppLinks();

  WebSocket? _socket;
  RTCPeerConnection? _pc;
  MediaStream? _stream;
  StreamSubscription<Uri>? _linkSub;

  LinkState _state = LinkState.idle;
  String _status = '';
  bool _front = false;
  Quality _quality = Quality.fhd;
  Framing _framing = Framing.landscape;
  bool _keepAlive = false;

  bool _preview = true;


  bool _mirror = false;
  bool _flip = false;

  /// The computer this session is pointed at.
  PairingPayload? _target;
  List<PairingPayload> _saved = const [];

  bool _session = false;


  bool _restarting = false;

  DateTime? _liveSince;
  String? _videoTrackId;

  bool _disposed = false;

  bool get _live =>
      _state == LinkState.streaming || _state == LinkState.connecting;

  bool get _onStream => _session || _restarting;

  String deviceLabel(PairingPayload target) =>
      target.host == kUsbHost ? 'The cable' : target.name;

  @override
  void initState() {
    super.initState();
    unawaited(_renderer.initialize());
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    unawaited(_reloadSaved());
    unawaited(_initDeepLinks());
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_linkSub?.cancel());
    _teardown();
    _renderer.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // ---------------------------------------------------------------- pairing

  Future<void> _reloadSaved() async {
    // remember() puts the most recent computer at index 0, so the saved list
    // is already in "last used first" order and needs no separate field.
    final saved = await _store.known();
    if (!mounted) return;
    setState(() => _saved = saved);
  }

  /// Handles beamcam://connect?h=..&p=..&n=.. opened from the system camera app.
  Future<void> _initDeepLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) await _handleLink(initial);
      _linkSub = _appLinks.uriLinkStream.listen(
        (uri) => unawaited(_handleLink(uri)),
        onError: (Object e) => debugPrint('BeamCam: link stream — $e'),
      );
    } catch (e) {
      debugPrint('BeamCam: deep links unavailable — $e');
    }
  }

  Future<void> _handleLink(Uri uri) async {
    if (!mounted) return;
    final payload = PairingPayload.tryParse(uri.toString());
    if (payload == null) {
      _log('That link is not a BeamCam pairing code.', state: LinkState.failed);
      return;
    }
    await _connectTo(payload);
  }


  Future<void> _connectTo(PairingPayload target) async {
    // The loopback developer route is never worth remembering 
    if (target.host != kUsbHost) {
      await _store.remember(target);
      await _reloadSaved();
    }
    if (!mounted) return;

    if (_session) {
      setState(() => _restarting = true);
      await _teardown();
      if (!mounted) return;
    }
    setState(() {
      _restarting = false;
      _state = LinkState.idle;
      _target = target;
    });
    await _start();
  }

  Future<void> _forget(PairingPayload payload) async {
    await _store.forget(payload);
    await _reloadSaved();
  }

  Future<void> _forgetAll() async {
    await _store.clear();
    await _reloadSaved();
  }

  // ------------------------------------------------------------- capture


  Future<void> _setFraming(Framing framing) async {
    setState(() => _framing = framing);
    // Only bite while streaming; idle, the UI stays free to rotate.
    await SystemChrome.setPreferredOrientations(
      _onStream ? framing.orientations : DeviceOrientation.values,
    );
    // The activity takes a moment to actually turn; latching before it settles
    // would pin the old rotation.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _pinRotation();
  }

  /// Mirror and flip are pushed over signaling rather than applied on the
  /// phone: the desktop is already compositing every frame on the GPU, so it
  /// can flip for free.
  void _sendTransform() {
    _socket?.add(
      Signal('transform', {'mirror': _mirror, 'flip': _flip}).encode(),
    );
  }

  void _setTransform({bool? mirror, bool? flip}) {
    setState(() {
      _mirror = mirror ?? _mirror;
      _flip = flip ?? _flip;
    });
    _sendTransform();
  }

  /// Freezes the outgoing rotation tag natively. Without this, backgrounding
  /// the app flips the stream to portrait, because libwebrtc reads the display
  /// rotation rather than the orientation we asked the activity for.
  Future<void> _pinRotation() async {
    final trackId = _videoTrackId;
    if (trackId == null) return;
    try {
      await _serviceChannel.invokeMethod('pinRotation', {'trackId': trackId});
    } on PlatformException catch (e) {
      _log('Rotation pin failed: ${e.message}');
    } on MissingPluginException {
      // Non-Android host; rotation is handled by the platform there.
    }
  }

  Future<void> _setKeepAlive(bool enabled) async {
    setState(() => _keepAlive = enabled);
    // Only hold the service while there is actually something to stream.
    await _syncBackgroundService(shouldRun: enabled && _live);
  }

  Future<void> _syncBackgroundService({required bool shouldRun}) async {
    // Android is the only platform where a background capture is possible at
    // all, so it is the only one we ask.
    if (!Platform.isAndroid) return;
    try {
      await _serviceChannel.invokeMethod(
        shouldRun ? 'startBackground' : 'stopBackground',
      );
    } on PlatformException catch (e) {
      _log('Background service: ${e.message}');
    } on MissingPluginException {
      // Nothing registered on this host.
    }
  }

  /// Stops the render without touching the capture graph, so the computer's
  /// picture is unaffected and the GPU stops compositing a texture nobody is
  /// watching.
  void _setPreview(bool on) {
    setState(() => _preview = on);
    if (_stream != null) _renderer.srcObject = on ? _stream : null;
  }

  void _log(String msg, {LinkState? state}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      if (state != null) _state = state;
    });
  }

  Future<void> _start() async {
    if (_state == LinkState.connecting || _state == LinkState.streaming) return;
    final target = _target;
    if (target == null) return;

    // Set synchronously, before the first await, so the view never renders a
    // frame of the device list between the tap and the streaming screen.
    setState(() {
      _session = true;
      _state = LinkState.connecting;
      _status = 'Opening the camera…';
    });

    try {
      final preset = _quality;
      _stream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': _front ? 'user' : 'environment',
          'width': {'ideal': preset.w},
          'height': {'ideal': preset.h},
          'frameRate': {'ideal': preset.fps},
        },
      });
      _renderer.srcObject = _preview ? _stream : null;
      if (mounted) setState(() {});

      final videoTracks = _stream!.getVideoTracks();
      _videoTrackId = videoTracks.isEmpty ? null : videoTracks.first.id;
      // Let the preview settle so the latched rotation is the correct one.
      // Order matters: the capturer takes its rotation from the activity, so
      // the lock has to be in place and settled before the pin is latched.
      // Pinning first captures whatever rotation the phone happened to be in.
      await SystemChrome.setPreferredOrientations(_framing.orientations);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _pinRotation();

      if (_keepAlive) await _syncBackgroundService(shouldRun: true);

      final name = deviceLabel(target);
      _log('Reaching $name…');
      final socket = await WebSocket.connect(
        'ws://${target.host}:${target.port}$kSignalPath',
      ).timeout(const Duration(seconds: 8));
      _socket = socket;

      final pc = await createPeerConnection(kRtcConfig);
      _pc = pc;

      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        socket.add(Signal.ice(candidate).encode());
      };

      pc.onConnectionState = (s) {
        switch (s) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _liveSince = DateTime.now();
            // The header carries who; the readout below carries where and in
            // what format. Saying the address in both places just doubles the
            // reading without adding a fact.
            _log(name, state: LinkState.streaming);
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _log(
              'Lost the video path. Check both devices are on the same network.',
              state: LinkState.failed,
            );
            unawaited(_teardown());
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            // Usually transient — ICE often recovers on its own, so this stays
            // on the streaming screen and says so rather than bailing out.
            _log(
              '$name dropped off. Reconnecting…',
              state: LinkState.connecting,
            );
          default:
            break;
        }
      };

      for (final track in _stream!.getTracks()) {
        await pc.addTrack(track, _stream!);
      }

      socket.listen(
        (raw) => _onSignal(Signal.decode(raw as String)),
        onDone: () {
          // Our own teardown closes this socket too; only a close we did not
          // ask for is news.
          if (!identical(_socket, socket)) return;
          _log('$name closed the connection.', state: LinkState.failed);
          unawaited(_teardown());
        },
        onError: (Object e) {
          if (!identical(_socket, socket)) return;
          _log('Connection error — $e', state: LinkState.failed);
          unawaited(_teardown());
        },
      );

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _capBitrate(pc, preset.maxBitrate, preset.fps);
      socket.add(
        Signal('offer', {'sdp': offer.sdp, 'sdpType': offer.type}).encode(),
      );
      _log('Waiting for $name to answer…');
    } on TimeoutException {
      _log(
        '${deviceLabel(target)} did not answer at ${target.host}. Open BeamCam '
        'on your computer, then try again.',
        state: LinkState.failed,
      );
      await _teardown();
    } catch (e) {
      _log('Could not start — $e', state: LinkState.failed);
      await _teardown();
    }
  }

  /// A ceiling, not a target. Without it the encoder happily spends 20 Mbps on
  /// 1080p60 and the first congested moment collapses the whole link.
  Future<void> _capBitrate(RTCPeerConnection pc, int bps, int fps) async {
    try {
      RTCRtpSender? video;
      for (final sender in await pc.getSenders()) {
        if (sender.track?.kind == 'video') {
          video = sender;
          break;
        }
      }
      if (video == null) return;

      final params = video.parameters;
      final encodings = params.encodings;
      // Some platforms hand back parameters before the encoder has published
      // an encoding, and setParameters rejects a changed encoding count. Leave
      // the default cap in place rather than fabricating a layer.
      if (encodings == null || encodings.isEmpty) {
        debugPrint('BeamCam: no encodings yet, bitrate cap skipped');
        return;
      }
      for (final encoding in encodings) {
        encoding.maxBitrate = bps;
        // 1080p and 1080p60 differ only in frame rate, so capping bitrate
        // alone leaves the two presets indistinguishable.
        encoding.maxFramerate = fps;
      }
      await video.setParameters(params);
    } catch (e) {
      debugPrint('BeamCam: bitrate cap failed — $e');
    }
  }

  Future<void> _onSignal(Signal signal) async {
    final pc = _pc;
    if (pc == null) return;

    switch (signal.type) {
      case 'answer':
        await pc.setRemoteDescription(
          RTCSessionDescription(
            signal.data['sdp'] as String,
            signal.data['sdpType'] as String,
          ),
        );
        _log('Connecting the video…');
      case 'ice':
        await pc.addCandidate(signal.toCandidate());
      default:
        break;
    }
  }

  Future<void> _teardown() async {
    // Hand rotation back to the user the moment streaming stops.
    if (!_disposed && mounted) {
      setState(() {
        _session = false;
        _liveSince = null;
      });
    } else {
      _session = false;
      _liveSince = null;
    }

    await _syncBackgroundService(shouldRun: false);
    if (_videoTrackId != null) {
      try {
        await _serviceChannel.invokeMethod('unpinRotation', {
          'trackId': _videoTrackId,
        });
      } on MissingPluginException {
        // Nothing to unpin off Android.
      } on PlatformException catch (e) {
        debugPrint('BeamCam: unpin failed — ${e.message}');
      }
      _videoTrackId = null;
    }
    // Cleared before the close so the socket's own onDone can tell a teardown
    // we asked for from one the desktop initiated.
    final socket = _socket;
    _socket = null;
    await socket?.close();
    final pc = _pc;
    _pc = null;
    await pc?.close();
    for (final track in _stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _stream?.dispose();
    _stream = null;
    if (!_disposed) _renderer.srcObject = null;
  }

  Future<void> _stop() async {
    // Hand rotation back to the user only when the session really ends.
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    await _teardown();
    _log('Stopped', state: LinkState.idle);
  }

  /// Restarting the whole session is heavier than swapping the track, but it
  /// keeps renegotiation out of the prototype.
  Future<void> _restartWith(void Function() mutate) async {
    final wasLive = _session;
    if (wasLive) setState(() => _restarting = true);
    await _teardown();
    if (!mounted) return;
    // _start() refuses to run unless the link is idle, so the state has to be
    // cleared here — otherwise flipping the camera tears the session down and
    // the restart silently no-ops, leaving a dead link.
    setState(() {
      _state = LinkState.idle;
      _restarting = false;
      mutate();
    });
    if (wasLive) await _start();
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return _onStream ? _streamScreen(context) : _connectScreen();
  }

  Widget _connectScreen() {
    return ConnectView(
      saved: _saved,
      onConnect: (p) => unawaited(_connectTo(p)),
      onForget: (p) => unawaited(_forget(p)),
      onForgetAll: () => unawaited(_forgetAll()),
      error: _state == LinkState.failed ? _status : null,
    );
  }

  Widget _streamScreen(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to computers',
          onPressed: () => unawaited(_stop()),
        ),
        title: Text(_target?.name ?? 'Streaming'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text(
                _state.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: _state == LinkState.streaming
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: landscape
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
                      child: _stage(context),
                    ),
                  ),
                  SizedBox(
                    width: 360,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(8, 8, 16, 16),
                      child: _controls(context),
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _stage(context),
                  const SizedBox(height: 20),
                  _controls(context),
                ],
              ),
      ),
    );
  }

  /// Timer, picture and the one action. Everything else is a setting.
  Widget _stage(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        _Elapsed(since: _liveSince),
        const SizedBox(height: 20),
        if (_preview) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              // Clip one radius inside the border so the video does not bleed
              // over the outline.
              child: ClipRRect(
                borderRadius: BorderRadius.circular(19),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ColoredBox(
                      color: Colors.black,
                      child: _stream == null
                          ? const SizedBox.shrink()
                          : RTCVideoView(
                              _renderer,
                              mirror: _front,
                              objectFit: RTCVideoViewObjectFit
                                  .RTCVideoViewObjectFitCover,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ] else
          // No placeholder: an off preview should cost no space at all.
          const SizedBox(height: 8),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.errorContainer,
              foregroundColor: theme.colorScheme.onErrorContainer,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 28),
            ),
            onPressed: () => unawaited(_stop()),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Stop streaming'),
          ),
        ),
      ],
    );
  }

  Widget _controls(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.cameraswitch_outlined),
            title: const Text('Camera'),
            subtitle: Text(_front ? 'Front' : 'Back'),
            onTap: () => unawaited(_restartWith(() => _front = !_front)),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.high_quality_outlined),
            title: const Text('Quality'),
            subtitle: Text('${_quality.label} · ${_quality.note}'),
            onTap: () => unawaited(_pickQuality(context)),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(_framing.icon),
            title: const Text('Framing'),
            subtitle: Text(_framing.label),
            onTap: () => unawaited(_pickFraming(context)),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.flip),
            title: const Text('Mirror'),
            subtitle: const Text('Flips left to right'),
            value: _mirror,
            onChanged: (v) => _setTransform(mirror: v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.flip_camera_android_outlined),
            title: const Text('Flip'),
            subtitle: const Text('Turns the picture upside down'),
            value: _flip,
            onChanged: (v) => _setTransform(flip: v),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_outlined),
            title: const Text('Preview'),
            subtitle: const Text('Turning it off saves battery'),
            value: _preview,
            onChanged: _setPreview,
          ),
          // Android only: iOS suspends capture the moment the app leaves the
          // screen, with no equivalent to a foreground service.
          if (Platform.isAndroid) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile(
              secondary: const Icon(Icons.play_circle_outline),
              title: const Text('Keep streaming in background'),
              subtitle: const Text('Shows a notification while active'),
              value: _keepAlive,
              onChanged: (v) => unawaited(_setKeepAlive(v)),
            ),
          ],
        ],
      ),
    );
  }

  /// MUST stay a modal bottom sheet: showDialog crashes the macOS AOT compiler
  /// and this file compiles into the desktop build.
  Future<T?> _pickOne<T>(
    BuildContext context,
    List<T> options,
    Widget Function(T value, ValueChanged<T?> onChanged) tile,
  ) => showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              tile(o, (v) => Navigator.of(context).pop(v)),
          ],
        ),
      ),
    ),
  );

  Future<void> _pickQuality(BuildContext context) async {
    final picked = await _pickOne<Quality>(
      context,
      Quality.values,
      (q, onChanged) => RadioListTile<Quality>(
        value: q,
        groupValue: _quality,
        title: Text(q.label),
        subtitle: Text(q.spec),
        secondary: Text(q.note),
        onChanged: onChanged,
      ),
    );
    if (picked != null && picked != _quality) {
      await _restartWith(() => _quality = picked);
    }
  }

  Future<void> _pickFraming(BuildContext context) async {
    final picked = await _pickOne<Framing>(
      context,
      Framing.values,
      (f, onChanged) => RadioListTile<Framing>(
        value: f,
        groupValue: _framing,
        title: Text(f.label),
        subtitle: Text(f.note),
        secondary: Icon(f.icon),
        onChanged: onChanged,
      ),
    );
    if (picked != null && picked != _framing) await _setFraming(picked);
  }
}

/// Counts up while live, owning its own timer so the once-a-second rebuild
/// never touches the video texture above it.
class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.since});

  final DateTime? since;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final since = widget.since;
    final elapsed = since == null
        ? Duration.zero
        : DateTime.now().difference(since);
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');

    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$minutes:$seconds',
        style: theme.textTheme.titleMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
