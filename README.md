# ExtendReality

An iOS 18 spatial workspace for USB-C display glasses, initially targeting an iPhone 15 Pro and XREAL Air v1.

## Implemented MVP

- Independent `UIWindowSceneSessionRoleExternalDisplayNonInteractive` scene for the glasses.
- AirPods-based 3DoF head tracking through `CMHeadphoneMotionManager`, with recenter, smoothing, roll compensation, and automatic head-locked fallback.
- Persisted multi-window workspace with focus, close, minimize, move, scale, and recenter controls.
- iPhone controller with trackpad, cursor/arrange/scroll modes, keyboard, Home, Back, and media controls.
- Apple Watch controller with gyroscope pointer input, Digital Crown scrolling, Double Tap click, recenter, app launching, and window focus/minimize/close actions.
- Live `WKWebView` browser surface with a JavaScript cursor bridge.
- Photos/Files image and video surface backed by AVFoundation.
- YouTube IFrame player, URL parsing, Data API search, and phone-side playback controls.
- RoyalVNCKit-backed VNC client for macOS Screen Sharing, including authentication, framebuffer updates, pointer, scroll, keyboard, and reconnect controls.
- SwiftData workspace persistence and Keychain storage for VNC passwords.

## Build

The Xcode project is generated from `project.yml`:

```sh
xcodegen generate
```

Open `ExtendReality.xcodeproj` and run on a physical USB-C iPhone. `project.yml` contains the current development team; replace `DEVELOPMENT_TEAM` there when building with another Apple Developer account. The RoyalVNCKit dependency is pinned to commit `337197afdb32020d3dfdb7d058989115b740cdc4` because its 1.1.0 tag currently contains a branch dependency that SwiftPM cannot resolve from a stable release.

The companion watch app targets watchOS 11. Run the `ExtendReality` scheme on a paired iPhone/Apple Watch so Xcode installs both apps. Open ExtendReality on both devices, tap the gyroscope button to arm pointer motion, rotate the Digital Crown to scroll, and use the primary Double Tap gesture (Apple Watch Series 9/Ultra 2 or newer) to click.

`project.yml` explicitly embeds and signs the dynamic `RoyalVNCKit.framework`. Keep `embed: true` and `codeSign: true` on that package dependency; otherwise a device build links successfully but terminates at launch with `Library not loaded: @rpath/RoyalVNCKit.framework/RoyalVNCKit`.

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

## Deferred integrations

- BLE IMU tracker for actual head pose on XREAL Air v1.
- Google Sign-In account surfaces after real OAuth credentials are supplied.
- ScreenCaptureKit/VideoToolbox Mac companion implementing the existing `RemoteDesktopSession` boundary.
