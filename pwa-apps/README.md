# ExtendReality pilot PWAs

This workspace contains three static apps for validating the ExtendReality PWA host:

- **Spatial Board** — an Excalidraw-based offline whiteboard with IndexedDB persistence and compact widget mode.
- **PWA Lab** — diagnostics for Service Worker, Cache Storage, IndexedDB, WebKit media permissions, and ExtendReality host API v3 including spatial-window composition.
- **Spatial Video** — a spatial online player plus an OPFS/IndexedDB library for user-owned offline media. YouTube content remains online-only and uses the official embedded player.

Spatial Video can optionally connect a Google account with the read-only YouTube scope. It builds a newest-first feed from recent uploads by subscribed channels; the YouTube Data API does not expose the personalized Home recommendations feed. The app ships with its Google OAuth **Web application** client ID and still allows an override in Spatial Video settings. Configure the OAuth client with `http://127.0.0.1:5175` for local development and the deployed HTTPS origin (currently `https://spectraldragon.github.io`) for production. OAuth client secrets must never be included in this static PWA. Short-lived access tokens remain in memory and are removed on reload or disconnect.

## Build

Node.js 22.12 or newer is required.

```sh
npm install
PWA_PUBLIC_BASE_URL=https://apps.your-domain.example npm run build
```

The deployable static site is assembled in `dist/`:

```text
dist/
├── catalog.json
├── pwa-lab/
├── spatial-board/
└── spatial-video/
```

The same build also refreshes `ExtendRealityPWAStudio/Resources/PWAApps`, which is
copied into the macOS Studio app bundle as an offline production preview.

Upload the complete directory to the HTTPS origin used during the build. Configure `ExtendRealityPWACatalogURL` as `https://apps.your-domain.example/catalog.json`, regenerate the Xcode project, and open **Web App Store** in the controller.

The catalog generator accepts an origin either through the environment or as an argument:

```sh
npm run catalog -- https://apps.your-domain.example
```

## Browser development

```sh
npm run dev:board
npm run dev:lab
npm run dev:video
```

Localhost is suitable for browser development because browsers treat it as a secure development context. The iOS host deliberately accepts only HTTPS manifest URLs, so test the complete installation flow from a trusted HTTPS deployment or tunnel.

## GitHub Pages

The repository workflow deploys the site as a GitHub project Page at `https://spectraldragon.github.io/ExtendedReality/`. Project Pages require a repository path prefix, so the workflow builds with both:

```sh
PWA_PUBLIC_BASE_URL=https://spectraldragon.github.io/ExtendedReality
PWA_BASE_PATH=/ExtendedReality
```

After the first successful deployment, use `https://spectraldragon.github.io/ExtendedReality/catalog.json` as `ExtendRealityPWACatalogURL`.

## Validation flow

1. Install Spatial Board, create a drawing, close and reopen its window, then disconnect the network and reopen it.
2. Open Spatial Board as a widget and confirm the compact, read-only canvas.
3. Install PWA Lab with selected permissions and run safe checks.
4. Exercise each native capability individually. Denied host permissions must produce a visible failure.
5. Open the external-origin probe and confirm it leaves the PWA surface.
6. Install Spatial Video with Spatial Windows permission, confirm the four-panel layout, and load a YouTube URL.
7. Import a permitted MP4/WebM/MOV/M4V file, disconnect the network, relaunch it, and confirm offline playback.
8. Uninstall each app and confirm its windows and private WebKit data are removed.
