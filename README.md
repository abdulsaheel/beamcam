# BeamCam

Use an Android phone as a webcam on macOS. One Flutter codebase, two roles: the
phone captures and sends, the Mac receives and displays.

## Why this exists

Every open-source Android→webcam project on macOS routes video through OBS.
[droidcam-obs-plugin](https://github.com/dev47apps/droidcam-obs-plugin) is an OBS
plugin with a closed-source phone app.
[RemoteCam](https://github.com/Ruddle/RemoteCam) is MJPEG-over-HTTP into an OBS
media source. [Mobile-Webcam](https://github.com/soubhagyajit/Mobile-Webcam)
ships a real virtual camera but only on Windows. Iriun and Camo do the whole job
natively and are both closed source.

Nothing open-source delivers Android → **native macOS virtual camera**.

Note this is deliberately Android-only. macOS has shipped Continuity Camera
since macOS 13, so an iPhone already does this natively and better. Android is
the case Apple will not serve.

## Status

| Stage | What it does | State |
|---|---|---|
| 1 | Phone captures, Mac receives and renders over WebRTC | **working** |
| 2 | CoreMediaIO extension so Meet/Brave list it directly | **installed and enabled** |
| 3 | Background capture, pinned rotation | **working** |
| 4 | Frame bridge: received video → extension sink stream | **working** |
| 5 | Torch/zoom/focus, bitrate tuning | not started |

`system_profiler SPCameraDataType` lists **BeamCam** as a capture device and it
serves the phone's live feed at 1280×720/30fps. The placeholder (dark frame,
moving blue bar) now appears only when no frame has arrived for 2 seconds — i.e.
when the phone is disconnected.

### The CMIO sink trap

`kCMIOStreamPropertyDirection` is **not** a reliable way to find the sink stream.
Measured on this device, the *source* stream reports `direction=1` and the *sink*
reports `direction=0` — the header's "0 means output" is relative to the client,
not the extension. Matching on `direction == 1` selects the source stream, and
every enqueue then fails with `-12773 kCMSimpleQueueError_QueueIsFull` forever
while the extension never sees a frame. `CMIOSinkClient` matches by stream name
first for this reason.

Also required before enumeration, or the DAL hides system-extension cameras from
the process entirely:

```swift
CMIOObjectSetPropertyData(kCMIOObjectSystemObject,
                          kCMIOHardwarePropertyAllowScreenCaptureDevices = 1)
```

## The naming rule that cost a day

A system extension bundle **must be filed under its own bundle identifier**:

```
Contents/Library/SystemExtensions/<CFBundleIdentifier>.systemextension
```

`sysextd` builds that path from the identifier and never scans the directory, so
`CameraExtension.systemextension` holding id
`com.jovaristech.beamcam.CameraExtension` failed with `OSSystemExtensionError`
code 4, "Extension not found in App bundle". Xcode's
`com.apple.product-type.system-extension` sets `PRODUCT_NAME =
$(PRODUCT_BUNDLE_IDENTIFIER)` for exactly this reason;
`add_camera_extension.rb` originally overrode it. Apple documents the rule in
the System Extensions Overview and a DTS engineer confirms it in
[forum thread 823200](https://developer.apple.com/forums/thread/823200).

Because `PRODUCT_NAME` then contains dots, `PRODUCT_MODULE_NAME` must be pinned
separately — dots are illegal in a Swift module name.

**`no policy, cannot allow apps outside /Applications` is a red herring.** It is
an unconditional "no MDM policy installed" trace; a *successful* activation logs
it too. The real location error is a different string with error code 3. Do not
debug against it.

**Developer ID system extensions must be notarized.** An unnotarized Developer
ID build fails with `code signature invalid` at `waiting for external
validation`. Apple Development signing skips notarization entirely and is the
correct choice for development.

## Architecture

```
Android (sender)                          macOS (receiver)
────────────────                          ────────────────
getUserMedia                              HttpServer :8787
     │                                          │
RotationPinner (native)                    WebSocket /ws
     │                                          │
RTCPeerConnection ──── offer ───────────▶       │
     │              ◀─── answer ─────────       │
     │              ◀──▶ ICE trickle ────▶      │
     │                                          │
     └──── SRTP video, direct over LAN ───▶ RTCVideoRenderer
```

The phone is always the offerer since it owns the media. The Mac adds a
`RecvOnly` transceiver and answers. `iceServers` is empty on purpose: both peers
are on one subnet, so host candidates pair immediately and STUN would only add
gathering latency.

| File | Role |
|---|---|
| `lib/signaling.dart` | Wire format, port, ICE config — shared by both ends |
| `lib/sender_page.dart` | Android: camera, framing, quality, background toggle |
| `lib/receiver_page.dart` | macOS: signaling server, answer, extension install UI |
| `android/.../RotationPinner.kt` | Freezes the outgoing rotation tag |
| `android/.../BeamCamService.kt` | Opt-in foreground service for background capture |
| `macos/CameraExtension/` | CoreMediaIO provider, device, source + sink streams |
| `macos/add_camera_extension.rb` | Recreates the extension target in the Xcode project |

### showDialog breaks the macOS AOT build

`showDialog` anywhere in code reachable from the macOS build fails the release
compile with:

```
Unexpected object (Class with illegal cid, full-aot):
Library:'package:flutter/src/widgets/_window_macos.dart' Class: _Rect
Dart snapshot generator failed with exit code -6
```

`showMenu` and `showModalBottomSheet` are fine — only `showDialog`. This bites
even in phone-only screens, because `main.dart` imports both pages, so
`sender_page.dart` and everything it reaches is compiled into the macOS binary
regardless of which page ever runs. Use an inline field or a pushed route
instead. Bisected against Flutter 3.44.9.

## Things that cost hours

- **`log` is shadowed by a shell function in zsh.** Every `log show` silently
  returned nothing, which looked like "logging is unavailable" and hid the real
  sysextd error for a long time. Use `/usr/bin/log`.
- **Gradle's wrapper download hangs from the JVM** while `curl` fetches the same
  URL fine — an IPv6 route that black-holes for Java. Seed the distribution into
  `~/.gradle/wrapper/dists` by hand and set
  `GRADLE_OPTS=-Djava.net.preferIPv4Stack=true`.
- **`flutter build macos` cannot pass `-allowProvisioningUpdates`.** Profiles
  have to be created by a `xcodebuild -scheme` run first. Raw `xcodebuild
  -target` fails outright because it skips Flutter's module-map codegen.
- **Register the Mac as a device** or no Mac App Development profile can be
  generated: `xcodebuild -allowProvisioningDeviceRegistration`.
- **The method channel must bind to the FlutterViewController's engine**
  (`MainFlutterWindow`), not to anything reachable from
  `applicationDidFinishLaunching` — otherwise every call is a
  `MissingPluginException`.
- **`os_log` never reaches stderr.** Use `NSLog`, or write to a file in the app
  group container, when debugging a LaunchServices-started app.
- **`org.webrtc.*` is not on the app module's classpath.** flutter_webrtc
  declares it `implementation`, so `RotationPinner` needs its own `compileOnly`
  dependency at a matching version.
- **`adb` lists the phone twice** (mDNS + IP), so bare `adb install` fails with
  "more than one device". Pin with `-s`.
- Camera rotation follows **display rotation**, not the activity's requested
  orientation — which is why backgrounding flipped the stream to portrait until
  `RotationPinner` latched it.

## Running it

```sh
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export GRADLE_OPTS="-Djava.net.preferIPv4Stack=true"

flutter build apk --release
adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk

flutter build macos --release   # needs full Xcode
```

The Mac app prints its LAN addresses while waiting; type one into the phone.

## License

MIT.
