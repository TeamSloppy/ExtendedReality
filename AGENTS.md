# ExtendReality Agent Guide

## Project configuration

- `project.yml` is the source of truth for Xcode targets, schemes, build settings, entitlements, and Info.plist values.
- Regenerate `ExtendReality.xcodeproj` with `xcodegen generate` after changing `project.yml` or adding target files.
- Do not hand-edit `ExtendReality.xcodeproj/project.pbxproj`; generated changes should come from XcodeGen.
- Preserve unrelated work in the working tree. This repository is often used with uncommitted changes in progress.

## PWA Studio

`ExtendRealityPWAStudio` is a macOS 15+ developer tool for previewing ExtendReality PWAs inside a glasses-style spatial viewport. It is a separate target and scheme from the ScreenCaptureKit companion app `ExtendRealityMac`.

Important locations:

- `ExtendRealityPWAStudio/App/` — application entry point and macOS commands.
- `ExtendRealityPWAStudio/Stores/StudioAppModel.swift` — app-wide preview state, fixtures, panel sessions, transforms, and logs.
- `ExtendRealityPWAStudio/Web/StudioWebSession.swift` — `WKWebView`, host API v3 injection, same-origin policy, permissions, console bridge, and Spatial Windows messages.
- `ExtendRealityPWAStudio/Views/GlassesViewport.swift` — 16:9 simulated glasses canvas, panels, spatial chrome, move, scale, and distance controls.
- `ExtendRealityPWAStudio/Views/RuntimeInspectorView.swift` — permissions, fixture data, transform state, and console output.
- `ExtendRealityPWAStudioTests/` — URL, origin-policy, projection, and fixture-contract tests.

### Shared host contract

The PWA Studio target compiles these existing iOS source files directly:

- `ExtendReality/PWA/PWAApp.swift`
- `ExtendReality/Domain/WorkspaceModels.swift`

They define the shared manifest, capability, origin, display-mode, and spatial-layout types. Prefer extending this shared contract over creating macOS-only duplicates. Any change must continue to compile for both iOS and macOS.

The injected JavaScript API is `window.extendReality` version 3. Preserve these rules:

- Host data methods require their matching `PWACapability` grant.
- Only the primary PWA frame can mutate the Spatial Windows layout.
- Secondary panels receive host data access but not the windows mutation API.
- Spatial layouts contain 1–8 valid panels.
- Secondary web panels must remain on the primary PWA's scheme, host, and port.
- Top-level external links may open in the system browser only when activated by the user.

### Security boundary

- Keep App Sandbox and Hardened Runtime enabled for `ExtendRealityPWAStudio`.
- Keep the network client, camera, microphone, and corresponding usage descriptions explicit.
- Do not launch Node, npm, Vite, shell scripts, or arbitrary executables as child processes of the app.
- Vite runs as a separate developer process through `script/run_pwa_dev_server.sh`.
- Do not add an unrestricted native or shell bridge to PWA JavaScript.

### Realtime development

Start a PWA server in a separate terminal:

```sh
./script/run_pwa_dev_server.sh lab
./script/run_pwa_dev_server.sh board
```

Preset endpoints:

- PWA Lab: `http://127.0.0.1:5173/pwa-lab/`
- Spatial Board: `http://127.0.0.1:5174/spatial-board/`

Both use the Vite HMR client, so source changes should update the embedded `WKWebView` without a manual reload. Custom local HTTP and HTTPS URLs can be entered in the Studio toolbar.

Build and launch the Studio with:

```sh
./script/build_and_run_pwa_studio.sh
./script/build_and_run_pwa_studio.sh --verify
```

The Codex environment also exposes a `Run PWA Studio` action.

### macOS interaction conventions

- Let the embedded `WKWebView` receive normal pointer, scrolling, keyboard, focus, selection, and drag events directly.
- Keep spatial move and scale gestures on chrome outside the web content.
- Important actions must remain available through visible controls and macOS commands/keyboard shortcuts.
- Use system-adaptive materials and semantic colors around the intentionally dark glasses viewport.
- Preserve visible keyboard focus, accessibility labels, and reduced-motion behavior.

## Verification

After PWA Studio changes, run the narrow checks first:

```sh
xcodegen generate
xcodebuildmcp macos build --project-path ExtendReality.xcodeproj --scheme ExtendRealityPWAStudio
xcodebuildmcp macos test --project-path ExtendReality.xcodeproj --scheme ExtendRealityPWAStudio
```

Verify the web workspace as well:

```sh
cd pwa-apps
npm test
npm run build
```

For runtime work, launch a Vite preset and confirm that the page, `/@vite/client` under the configured base path, host API v3, permission denial paths, and multi-panel composition all work.

The Spatial Board production bundle currently emits a large-chunk warning. Treat it as a performance follow-up, not a build failure, unless the task specifically addresses bundle size.
