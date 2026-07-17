# ExtendReality

An iOS 18 spatial workspace for USB-C display glasses, initially targeting an iPhone 15 Pro and XREAL Air v1.

## Implemented MVP

- Independent `UIWindowSceneSessionRoleExternalDisplayNonInteractive` scene for the glasses.
- AirPods-based 3DoF head tracking through `CMHeadphoneMotionManager`, with recenter, smoothing, roll compensation, and automatic head-locked fallback.
- Persisted multi-window workspace with focus, close, minimize, move, scale, and recenter controls.
- iPhone controller with trackpad, cursor/arrange/scroll modes, keyboard, Home, Back, and media controls.
- Apple Watch controller with gyroscope pointer input, Digital Crown scrolling, Double Tap click, recenter, app launching, and window focus/minimize/close actions.
- Live `WKWebView` browser surface with a JavaScript cursor bridge.
- Curated PWA mini-app store with isolated per-app WebKit storage, window/widget launch modes, origin restrictions, age gating, camera/microphone consent, and uninstall cleanup.
- Photos/Files image and video surface backed by AVFoundation.
- YouTube IFrame player, URL parsing, Data API search, and phone-side playback controls.
- RoyalVNCKit-backed VNC client for macOS Screen Sharing, including authentication, framebuffer updates, pointer, scroll, keyboard, and reconnect controls.
- Native macOS companion with ScreenCaptureKit capture, single/multi-display layouts, ultrawide composition, and Bonjour-advertised MJPEG streaming.
- SwiftData workspace persistence and Keychain storage for VNC passwords.
- Consent-gated Core Location, read-only HealthKit activity summaries, and system Focus Status, including a per-app PWA data bridge.

## Build

The Xcode project is generated from `project.yml`:

```sh
xcodegen generate
```

Open `ExtendReality.xcodeproj` and run on a physical USB-C iPhone. `project.yml` contains the current development team; replace `DEVELOPMENT_TEAM` there when building with another Apple Developer account. The RoyalVNCKit dependency is pinned to commit `337197afdb32020d3dfdb7d058989115b740cdc4` because its 1.1.0 tag currently contains a branch dependency that SwiftPM cannot resolve from a stable release.

The companion watch app targets watchOS 11. Run the `ExtendReality` scheme on a paired iPhone/Apple Watch so Xcode installs both apps. Open ExtendReality on both devices, tap the gyroscope button to arm pointer motion, rotate the Digital Crown to scroll, and use the primary Double Tap gesture (Apple Watch Series 9/Ultra 2 or newer) to click.

`project.yml` explicitly embeds and signs the dynamic `RoyalVNCKit.framework`. Keep `embed: true` and `codeSign: true` on that package dependency; otherwise a device build links successfully but terminates at launch with `Library not loaded: @rpath/RoyalVNCKit.framework/RoyalVNCKit`.

## PWA Store

Set `ExtendRealityPWACatalogURL` in `project.yml` to an HTTPS endpoint serving the catalog document. Until it is configured, the native store intentionally shows an unconfigured state and does not offer third-party apps.

The catalog schema and pilot entries are documented in [`docs/pwa-catalog-v1.example.json`](docs/pwa-catalog-v1.example.json). The host contract, admission rules, and App Store constraints are in [`docs/pwa-host.md`](docs/pwa-host.md). Host API v2 uses `WKWebView`, exposes only reviewed read-only capabilities, and does not embed Node.js or an unrestricted native bridge.

Two deployable pilot apps live in [`pwa-apps`](pwa-apps): an offline Excalidraw-based **Spatial Board** and the **PWA Lab** host diagnostic suite. Their workspace generates the production static site and catalog for a chosen HTTPS origin.

## Hardware test

1. Run the app on the iPhone and connect XREAL Air directly over USB-C.
2. Confirm that the phone controller remains on the iPhone while the workspace appears on the glasses.
3. Disconnect and reconnect the cable; the external scene should recover and retain its layout.
4. Connect motion-capable AirPods and grant Motion access. Use **Reset** to establish the current forward direction; disconnecting the AirPods automatically returns the canvas to head-locked mode.
5. Direct DisplayPort does not expose a documented XREAL Air v1 IMU channel to iOS. `XREALPoseProvider` remains the boundary for a future supported USB/HID or BLE tracker.
6. Open the Watch app while the iPhone app is active. Confirm wrist rotation moves the cursor, Digital Crown scrolls the focused surface, and Double Tap activates the click button. Tune pointer sensitivity in the Watch app if needed.

## Spatial debug website

`web-spatial-tracker` contains a dependency-free WebSocket relay and browser
viewer for live AirPods/head pose, phone motion, Watch status, device placement,
gaze direction, and workspace window transforms. See
[`web-spatial-tracker/README.md`](web-spatial-tracker/README.md) for launch and
Xcode connection instructions.

## YouTube setup

Create a Google Cloud project, enable YouTube Data API v3, and place the API key in the app's Settings sheet. Search requires the key; direct playback by URL/video ID does not. Google account OAuth needs a Google iOS OAuth client and URL configuration and is intentionally not shipped with placeholder credentials.

YouTube downloads and offline caching are not implemented. Offline playback accepts files selected from Photos or Files.

## macOS Screen Sharing

Enable **System Settings → General → Sharing → Screen Sharing** on the Mac. Add the hostname (for example `mac.local`), credentials, and port 5900 in the Mac window controls. Prefer a trusted local network because VNC transport security depends on the selected server authentication method.

## Native Mac companion

Run the `ExtendRealityMac` scheme on macOS 15 or newer, or use the Codex **Run** action backed by `script/build_and_run.sh`. Choose one of three layouts:

- **One display** streams one selected Mac display.
- **Multiple desktops** exposes every selected physical display as a separate MJPEG endpoint listed by `/manifest.json`.
- **Ultrawide** joins selected displays horizontally into a canvas capped at 5120 × 1440.

Press **Start**, grant Screen Recording permission when macOS asks, then open the LAN URL shown in the app. The root page shows the primary stream, `/stream.mjpeg` is the primary MJPEG endpoint, and `/display/<display-id>.mjpeg` addresses individual displays. The service is advertised as `_extend-reality._tcp` through Bonjour.

The MVP stream is intentionally unencrypted HTTP/MJPEG and should only be used on a trusted local network. Creating additional system-level virtual monitors is not available through a supported public macOS app API; the current multi-display mode uses physical displays. A separate signed display-driver strategy needs its own distribution and security design.

## Deferred integrations

- BLE IMU tracker for actual head pose on XREAL Air v1.
- Google Sign-In account surfaces after real OAuth credentials are supplied.
- VideoToolbox H.264 transport and a native iPhone receiver replacing the MJPEG compatibility stream.
- Evaluation of a separately distributed virtual-display driver for system-level synthetic monitors.
