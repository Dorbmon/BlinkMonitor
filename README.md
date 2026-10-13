# BlinkMonitor

A private desktop blink-frequency monitor: **Flutter for the dashboard, Swift for macOS camera / Vision / menu bar logic, and a Python OpenCV + MediaPipe backend for Linux**.

- Live blinks per minute in the macOS menu bar. Click it to open the dashboard; right-click for monitoring controls and Quit.
- Responsive Flutter dashboard with live tracking, daily totals, weighted averages, and 1 / 7 / 30-day charts.
- Session history, 90-day local retention, CSV export, camera selection, sensitivity, and recalibration.
- Linux V4L2 webcam support and a system-tray menu. Linux panels vary: the rate is shown in the tray menu / tooltip and, where supported, the panel label.
- Camera frames stay in memory and are discarded. No video recording, account, telemetry, or runtime network requests.

## Requirements

- Flutter 3.35+ / Dart 3.8+ (developed with Flutter 3.47.7). `pubspec.lock` pins the app dependencies.
- macOS 13+, a camera, and a configured Xcode installation. Open Xcode once to review its license and install required components. CocoaPods 1.16+ is required for the Linux desktop plugins’ macOS registrations; `flutter doctor -v` identifies missing tooling.
- Linux x86_64 with GTK 3, a V4L2 webcam, and Python 3.10–3.12. Other architectures need compatible MediaPipe wheels or a source build; they are not validated.

## Run on macOS

```sh
flutter pub get
flutter run -d macos
```

Click **Start monitoring**, allow camera access, and look at the screen with your eyes naturally open while calibration completes. Closing the dashboard keeps monitoring in the menu bar. Pausing or quitting turns off the camera. Sleep stops capture; monitoring resumes on wake if it was active.

For a release app:

```sh
./scripts/build-app.sh --open
```

Output: `build/macos/Build/Products/Release/BlinkMonitor.app`. Open `macos/Runner.xcworkspace` to work in Xcode. Distribution to other Macs requires your own Developer ID signing and notarization. The checked-in entitlements include camera access, app sandboxing, and user-selected file export.

If camera access was denied, use the dashboard’s **Open camera settings** button, enable BlinkMonitor, then start again. Camera selection and Refresh are in Settings.

## Run on Linux

Ubuntu / Debian development dependencies:

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
  libayatana-appindicator3-dev libstdc++-12-dev libgl1 python3-venv curl
./scripts/setup-linux-backend.sh
flutter pub get
flutter run -d linux
```

The setup script installs pinned Python packages in `${XDG_DATA_HOME:-$HOME/.local/share}/blinkmonitor/venv` and downloads the versioned Google Face Landmarker model with SHA-256 verification. Setup needs internet; monitoring does not. Select Python explicitly if needed:

```sh
PYTHON=python3.12 ./scripts/setup-linux-backend.sh
```

`./scripts/build-app.sh` creates a release bundle under `build/linux/`. For this development bundle, distribute the **entire bundle directory**, not only its executable, and run the backend setup on each machine. The packaged AppImage described below embeds Python and the model and does not require setup. The worker source is embedded as Flutter assets and extracted locally on startup, so launching a release build does not depend on the repository or working directory.

- Optional overrides: `BLINKMONITOR_PYTHON=/absolute/path/to/python` and `BLINKMONITOR_MODEL=/absolute/path/to/face_landmarker.task`.
- GNOME may require its AppIndicator extension for a visible tray icon. The dashboard works without a tray host. Closing the Linux window quits and releases the camera, avoiding an inaccessible background process on desktops without a visible tray.
- If permission is denied for `/dev/videoN`, check device access and your distribution’s video-group / session ACL setup. The app never changes device permissions.
- Multiple `/dev/videoN` nodes can belong to one webcam; choose the capture node if the default does not work.

## Automatic packages and releases

[Build and package](.github/workflows/ci.yml) runs on branch pushes, pull requests, and manual dispatch. Both platforms must pass static analysis and tests before packaging. Download the **BlinkMonitor-Linux** and **BlinkMonitor-macOS** artifacts from a completed Actions run:

- `BlinkMonitor-1.0.0-linux-x86_64.AppImage`: includes the Flutter app, bundled desktop libraries, relocatable Python 3.12, Python dependencies, and the checksum-verified Face Landmarker model. No backend installation or runtime download is needed. Make it executable, then run it. On hosts without FUSE, use `--appimage-extract-and-run`.
- `BlinkMonitor-1.0.0-macos-universal.zip`: contains `BlinkMonitor.app` for Apple Silicon and Intel, with file permissions and bundle metadata preserved.
- Each package has a `.sha256` file. AppImage builds target Ubuntu 22.04 or compatible newer Linux desktops.

Push a `v*` tag (for example `v1.0.0`) to publish both artifacts to a GitHub Release after successful builds. Update `version` in `pubspec.yaml` before tagging. The release job alone receives repository-write permission; PR builds cannot publish releases.

Local packaging commands:

```sh
./scripts/package-macos.sh  # macOS host
./scripts/package-linux.sh # Linux x86_64 host
```

The macOS app is ad-hoc signed, not Developer ID signed or notarized. The workflow does not have Apple credentials and does not claim Gatekeeper approval. Signing and notarization can be added when a Developer ID certificate and App Store Connect credentials are available.

## Detection and rate calculation

macOS uses `AVCaptureVideoDataOutput` and Vision face landmarks on serial background queues. Linux uses OpenCV V4L2 capture and MediaPipe Face Landmarker in a separate process. Both feed the same Flutter controller through a small measurement-only interface.

Both detectors calibrate open-eye geometry for at least two seconds and 40 valid samples. A bilateral close → reopen transition counts as a blink when closure lasts 25–800 ms, with hysteresis and a 180 ms refractory period. Winks, extended closures, face loss, large frame gaps, and multiple faces do not count as blinks. Eye geometry compensates for image aspect ratio and head roll; large yaw / pitch stops tracking. A long absence triggers recalibration.

The live value is **blink count ÷ valid tracked seconds × 60**, over a sliding 60-second window. It becomes available after five tracked seconds. Missing-face and calibration time are excluded. A zero rate means tracked time with no blinks; a dash means insufficient or unavailable tracking. History averages use summed blinks and exposure, not an average of per-minute rates. Partial minutes remain partial rather than being treated as full minutes.

These are approximate camera-based measurements, not clinical readings. Lighting, glasses, glare, camera frame rate, and posture affect accuracy. Use Settings to tune sensitivity or recalibrate. Real camera accuracy needs testing on your hardware.

## Data and architecture

```text
lib/src/ui/                 Flutter dashboard, history, settings, chart
lib/src/monitor_controller.dart  Lifecycle, sessions, rolling rate
lib/src/data/history.dart   Versioned JSON, atomic saves, CSV
lib/src/backend/           Swift channels / Linux JSON-lines process client
macos/Runner/              Swift camera pipeline, bridge, native menu bar
Sources/BlinkCore/          Pure Swift blink detector (also compiled into Runner)
backend/linux/             V4L2 / MediaPipe worker and equivalent detector
```

The macOS `com.dorbmon.blinkmonitor/control` method channel supports `cameras`, `start`, `stop`, `recalibrate`, `storageDirectory`, `updateStatus`, `showDashboard`, `openCameraSettings`, and `terminate`. Measurements and desktop actions arrive through `com.dorbmon.blinkmonitor/events`. The Linux worker implements the camera methods over stdin/stdout JSON lines, with request IDs and per-run IDs to discard stale frames. See [backend protocol](backend/linux/PROTOCOL.md).

The Flutter archive is saved atomically every ten seconds and when pausing or quitting. A crash may lose up to ten seconds. Unreadable archives are backed up before replacement. macOS stores `BlinkMonitor/history.json` in the app’s sandbox Application Support directory. Linux stores it under `${XDG_DATA_HOME:-$HOME/.local/share}/com.dorbmon.BlinkMonitor/BlinkMonitor/`. Clear history requires confirmation and resets the current session; CSV exports and unreadable-archive backups are separate files and are not deleted.

## Tests

```sh
flutter analyze
flutter test
swift test
python3 -m unittest discover -s backend/linux/tests -v
```

Swift tests cover calibration, timing, face loss, hysteresis, and geometry. Python tests cover detector behavior, command handling, and camera-worker lifecycle. Flutter tests cover rate math, persistence, lifecycle races, and dashboard interactions at desktop sizes. GitHub Actions validates both native platforms and builds release bundles. A physical camera is required for end-to-end accuracy and permission-prompt checks.

## Implementation references

- [Flutter platform channels](https://docs.flutter.dev/platform-integration/platform-channels)
- [Apple Vision eye landmarks](https://developer.apple.com/documentation/vision/vnfacelandmarks2d/lefteye)
- [MediaPipe Face Landmarker for Python](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker/python)
- [Linux tray plugin](https://pub.dev/packages/tray_manager/versions/0.5.2)
