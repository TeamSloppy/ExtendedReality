# ExtendReality PWA Host v2

ExtendReality runs curated HTML5/JavaScript apps in isolated `WKWebView` instances. Set `ExtendRealityPWACatalogURL` in `project.yml` to an HTTPS endpoint returning the catalog schema in `pwa-catalog-v1.example.json`.

## Runtime contract

- Each installation receives a stable, private `WKWebsiteDataStore` identifier.
- The PWA owns its Service Worker, Cache Storage, IndexedDB, and offline behavior.
- The host appends `extendDisplayMode=window|widget` to the launch URL.
- Top-level navigation stays inside `allowedOrigins`. User-activated external HTTP links open outside the PWA surface.
- Version 2 exposes a small read-only bridge as `window.extendReality`. No arbitrary Swift or Node bridge is available.
- `camera`, `microphone`, `location`, `health`, and `focusStatus` are host-managed capabilities. Every capability requires catalog declaration and explicit per-app consent. Native data additionally requires the corresponding iOS system permission.
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

`window.extendReality.version` is `2`. Health data is read-only and limited to today's step count and active energy plus the latest heart-rate sample from the last seven days. Location uses foreground, approximate-by-default access. Focus data only indicates whether notifications are currently silenced for ExtendReality; it does not disclose the Focus name.

## Catalog admission

The catalog is a curated index, not arbitrary sideloading. Before publishing an entry:

1. Validate HTTPS launch and universal-link URLs.
2. Review the app and every allowed origin.
3. Confirm its age rating and privacy disclosures.
4. Verify offline behavior in `WKWebView`.
5. Confirm requested capabilities are necessary.
6. Add reporting and removal procedures for hosted content.

Downloaded Node.js modules and native extensions are intentionally unsupported in the App Store build. Additional native capabilities require a new reviewed host API and may require prior approval from Apple under App Review Guideline 4.7.2.
