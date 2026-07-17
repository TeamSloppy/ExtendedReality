# ExtendReality pilot PWAs

This workspace contains two static apps for validating the ExtendReality PWA host:

- **Spatial Board** — an Excalidraw-based offline whiteboard with IndexedDB persistence and compact widget mode.
- **PWA Lab** — diagnostics for Service Worker, Cache Storage, IndexedDB, WebKit media permissions, and ExtendReality host API v2.

## Build

Node.js 22.12 or newer is required.

```sh
npm install
PWA_PUBLIC_ORIGIN=https://apps.your-domain.example npm run build
```

The deployable static site is assembled in `dist/`:

```text
dist/
├── catalog.json
├── pwa-lab/
└── spatial-board/
```

Upload the complete directory to the HTTPS origin used during the build. Configure `ExtendRealityPWACatalogURL` as `https://apps.your-domain.example/catalog.json`, regenerate the Xcode project, and open **Web App Store** in the controller.

The catalog generator accepts an origin either through the environment or as an argument:

```sh
npm run catalog -- https://apps.your-domain.example
```

## Browser development

```sh
npm run dev:board
npm run dev:lab
```

Localhost is suitable for browser development because browsers treat it as a secure development context. The iOS host deliberately accepts only HTTPS manifest URLs, so test the complete installation flow from a trusted HTTPS deployment or tunnel.

## Validation flow

1. Install Spatial Board, create a drawing, close and reopen its window, then disconnect the network and reopen it.
2. Open Spatial Board as a widget and confirm the compact, read-only canvas.
3. Install PWA Lab with selected permissions and run safe checks.
4. Exercise each native capability individually. Denied host permissions must produce a visible failure.
5. Open the external-origin probe and confirm it leaves the PWA surface.
6. Uninstall each app and confirm its windows and private WebKit data are removed.
