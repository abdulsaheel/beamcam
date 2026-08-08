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

/// Plain state labels. No bespoke palette — the surface colour and stock
/// Material components carry the state instead.
enum LinkState {
  idle('Ready'),
  connecting('Connecting'),
  streaming('Live'),
  failed('Problem');

  const LinkState(this.label);

  final String label;
}

/// The phone side, as one screen with two jobs.
///
/// Not connected, the screen *is* the list of computers it can reach — saved
/// ones first, discovered ones under them. Tapping one starts the stream and
/// the same screen becomes the streaming view. There is no pushed route in the
/// primary flow and no settings sheet in front of it, so a returning user goes
/// from launcher to live in a single tap.
///
/// The preview is deliberately demoted. It is capped at roughly a quarter of
/// the screen, it can be turned off entirely, and everything that matters —
/// link state, what is being sent, and where — is legible without it.

/// Opt-in only, and Android-only. The foreground service posts a permanent
/// notification and keeps the camera powered, so it runs when the user asks for
/// it and not before. iOS has no equivalent: AVCaptureSession is suspended the
/// moment the app leaves the screen and there is no workaround, which is why
/// the switch is hidden rather than shown-and-broken there.
const _serviceChannel = MethodChannel('beamcam/service');

/// WebRTC takes its capture rotation from the activity's orientation, so
/// forcing the activity is what actually rotates the outgoing video. Doing it
/// in-app matters because it overrides the system auto-rotate toggle — a phone
/// with rotation locked would otherwise be stuck sending portrait forever.
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

/// Capture ladder. Resolution, frame rate and the bitrate ceiling move
/// together, because picking them independently is a trap: 1080p60 inside a
/// 4 Mbps cap just looks like smeared 1080p30.
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

  String get spec {
    final mbps = maxBitrate / 1000000;
    final rounded = mbps == mbps.roundToDouble()
        ? mbps.toStringAsFixed(0)
        : mbps.toStringAsFixed(1);
    return '$w × $h · $fps fps · up to $rounded Mbps';
  }
}

class SenderPage extends StatefulWidget {
  const SenderPage({super.key, this.debugAutoConnect});

  /// Review-harness seam only. Production builds construct `SenderPage()` and
  /// leave this null.
  @visibleForTesting
  final PairingPayload? debugAutoConnect;

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
  Quality _quality = Quality.hd;
  Framing _framing = Framing.landscape;
  bool _keepAlive = false;

  /// On by default because framing yourself is the first thing anyone does,
  /// but capped small and switchable off. Turning it off stops the render, not
  /// the capture, so the computer keeps its picture.
  bool _preview = true;

  /// The computer this session is pointed at.
  PairingPayload? _target;
  List<PairingPayload> _saved = const [];

  /// True from the moment a connection attempt begins until teardown finishes.
  /// The screen switches on this rather than on [_state], so a momentary ICE
  /// disconnect reports itself in place instead of dumping the user back to the
  /// device list mid-call.
  bool _session = false;

  /// Held across the teardown/start pair inside [_restartWith] so flipping the
  /// camera or changing quality never flashes the device list.
  bool _restarting = false;

  DateTime? _liveSince;
  String? _videoTrackId;

  /// dispose() cannot await _teardown(), so the teardown's later half can run
  /// after the renderer is already gone. Writing srcObject then throws.
  bool _disposed = false;

  bool get _live =>
      _state == LinkState.streaming || _state == LinkState.connecting;

  bool get _onStream => _session || _restarting;

  /// "USB cable" reads oddly in a sentence; everything else is a computer name.
  String deviceLabel(PairingPayload target) =>
      target.host == kUsbHost ? 'The cable' : target.name;

  @override
  void initState() {
    super.initState();
    unawaited(_renderer.initialize());
    // Deliberately NOT locking here. Framing governs the outgoing video, not
    // how you hold the phone while picking a computer, so the lock is applied
    // when a stream starts and released when it ends.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    unawaited(_reloadSaved());
    unawaited(_initDeepLinks());
    final auto = widget.debugAutoConnect;
    if (auto != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connectTo(auto));
    }
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

  /// The replacement for the in-app QR scanner.
  ///
  /// The desktop shows a QR encoding `beamcam://connect?h=..&p=..&n=..`; the
  /// phone's own Camera app reads it and launches us with that URI. That is
  /// strictly fewer steps than any scanner we could ship, needs no camera
  /// permission before pairing, and works identically on both phone platforms.
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

  /// One entry point for every route in: tapping a saved computer, tapping a
  /// discovered one, following a scanned link, or typing an address. They all
  /// land here, so they all behave identically.
  Future<void> _connectTo(PairingPayload target) async {
    // The loopback developer route is never worth remembering — it is not a
    // computer, it is a cable.
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

  /// Rotating the activity is enough — libwebrtc's capturer watches display
  /// rotation and re-tags frames, so an active stream follows without
  /// renegotiating.
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
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _pinRotation();

      if (_keepAlive) await _syncBackgroundService(shouldRun: true);

      // Now the lock matters: the capturer takes its rotation from the
      // activity, so the frame shape is decided here.
      await SystemChrome.setPreferredOrientations(_framing.orientations);

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
        socket.add(
          Signal('ice', {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }).encode(),
        );
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
      await _capBitrate(pc, preset.maxBitrate);

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
  Future<void> _capBitrate(RTCPeerConnection pc, int bps) async {
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
        await pc.addCandidate(
          RTCIceCandidate(
            signal.data['candidate'] as String?,
            signal.data['sdpMid'] as String?,
            signal.data['sdpMLineIndex'] as int?,
          ),
        );
      default:
        break;
    }
  }

  Future<void> _teardown() async {
    // Hand rotation back to the user the moment streaming stops.
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
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
      busyHost: _state == LinkState.connecting ? _target?.host : null,
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
        // 2. A real back affordance: leaving the stream is the way back to the
        //    list of computers, so the arrow does exactly that.
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
                _state == LinkState.streaming ? 'Live' : _state.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: _state == LinkState.streaming
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Switch computer',
            icon: const Icon(Icons.swap_horiz),
            onPressed: () => unawaited(_stop()),
          ),
        ],
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

  Future<void> _pickQuality(BuildContext context) async {
    final picked = await showModalBottomSheet<Quality>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final q in Quality.values)
              RadioListTile<Quality>(
                value: q,
                groupValue: _quality,
                title: Text(q.label),
                subtitle: Text(q.spec),
                secondary: Text(q.note),
                onChanged: (v) => Navigator.of(context).pop(v),
              ),
          ],
        ),
      ),
    );
    if (picked != null && picked != _quality) {
      await _restartWith(() => _quality = picked);
    }
  }

  Future<void> _pickFraming(BuildContext context) async {
    final picked = await showModalBottomSheet<Framing>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in Framing.values)
              RadioListTile<Framing>(
                value: f,
                groupValue: _framing,
                title: Text(f.label),
                subtitle: Text(f.note),
                secondary: Icon(f.icon),
                onChanged: (v) => Navigator.of(context).pop(v),
              ),
          ],
        ),
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
