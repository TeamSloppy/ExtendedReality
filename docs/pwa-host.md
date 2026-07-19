# ExtendReality PWA Host v3

ExtendReality runs curated HTML5/JavaScript apps in isolated `WKWebView` instances. `ExtendRealityPWACatalogURL` in `project.yml` points to `https://xr.sloppy.team/plugins/catalog.json`, which returns the catalog schema in `pwa-catalog-v1.example.json`.

## Runtime contract

- Each installation receives a stable, private `WKWebsiteDataStore` identifier.
- The PWA owns its Service Worker, Cache Storage, IndexedDB, and offline behavior.
- The host appends `extendDisplayMode=window|widget` to the launch URL.
- Top-level navigation stays inside `allowedOrigins`. User-activated external HTTP links open outside the PWA surface.
- Version 3 exposes the read-only data bridge plus a constrained spatial-window API as `window.extendReality`. No arbitrary Swift or Node bridge is available.
- `camera`, `microphone`, `location`, `health`, `focusStatus`, and `spatialWindows` are host-managed capabilities. Every capability requires catalog declaration and explicit per-app consent. Native data additionally requires the corresponding iOS system permission.
- Uninstall closes the app's windows and removes its WebKit data store.

## Read-only data API

The host API is injected only into the main frame of an installed PWA. It is not available in the general browser. Each method returns a Promise and rejects when the app or system permission is missing.

```js
const location = await window.extendReality.getLocation();
// { latitude, longitude, horizontalAccuracy, timestamp }

const health = await window.extendReality.getHealthSummary();
// { steps, activeEnergyKilocalories, latestHeartRateBPM?, updatedAt }

const focus = await window.extendReality.getFocusStatus();
// { isFocused, updatedAt }
```

`window.extendReality.version` is `3`. Health data is read-only and limited to today's step count and active energy plus the latest heart-rate sample from the last seven days. Location uses foreground, approximate-by-default access. Focus data only indicates whether notifications are currently silenced for ExtendReality; it does not disclose the Focus name.

## Spatial windows API

An installed PWA that declares and receives `spatialWindows` can atomically replace its fixed panel composition. The primary panel reuses the original `WKWebView`; every panel with a `url` receives a separate `WKWebView` in the same private data store. URLs must stay inside `allowedOrigins`.

```js
await window.extendReality.windows.setLayout({
  primaryPanelID: 'primary',
  panels: [
    {
      id: 'primary',
      accessibilityLabel: 'Main editor',
      placement: { yaw: 0, pitch: 0, depth: 0, width: 0.72, height: 0.68, layer: 0 }
    },
    {
      id: 'tools',
      accessibilityLabel: 'Editor tools',
      url: '/tools/',
      placement: { yaw: 24, pitch: 1, depth: 0.08, width: 0.28, height: 0.42, layer: 1 }
    }
  ]
});

await window.extendReality.windows.update('tools', {
  accessibilityLabel: 'Editor tools',
  url: '/tools/compact/',
  placement: { yaw: 22, pitch: 0, depth: 0.05, width: 0.25, height: 0.36, layer: 1 }
});
await window.extendReality.windows.remove('tools');
await window.extendReality.windows.reset();
```

Layouts contain 1–8 unique panels. Relative yaw is limited to `-42...42°`, pitch to `-24...24°`, depth to `-0.5...0.5 m`, width to `0.15...1.5`, height to `0.10...1.2`, and layer to `-16...16`. Invalid layouts are rejected without changing the current composition. Only the primary PWA frame receives `windows`; secondary frames retain the data API but cannot mutate the group.

## Catalog admission

The catalog is a curated index, not arbitrary sideloading. Before publishing an entry:

1. Validate HTTPS launch and universal-link URLs.
2. Review the app and every allowed origin.
3. Confirm its age rating and privacy disclosures.
4. Verify offline behavior in `WKWebView`.
5. Confirm requested capabilities are necessary.
6. Add reporting and removal procedures for hosted content.

Downloaded Node.js modules and native extensions are intentionally unsupported in the App Store build. Additional native capabilities require a new reviewed host API and may require prior approval from Apple under App Review Guideline 4.7.2.
