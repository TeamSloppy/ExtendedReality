# Mac Application Sharing

## Goal

Mac Sharing can expose either the configured Mac displays or one running macOS
application. A selected application is rendered as a normal ExtendReality
workspace window, so it uses the same focus, move, scale, distance, minimize,
and close behavior as other spatial windows.

## User flow

1. The user opens **Controls → Apps → Mac** on iPhone or iPad.
2. ExtendReality discovers `ExtendRealityMac` through Bonjour.
3. The controller requests the current application catalog.
4. The user selects either the configured display layout or one application.
5. The Mac starts ScreenCaptureKit with the selected source and returns a stream
   session.
6. ExtendReality replaces the previous Mac stream windows with the endpoints in
   the new session.

Only running applications with a visible, normal-level window are listed. The
Mac companion itself is excluded.

## Protocol

The existing `_extend-reality._tcp` service remains the discovery boundary.

### Application catalog

`GET /api/v1/applications`

```json
{
  "version": 1,
  "applications": [
    {
      "id": "pid:321",
      "name": "Preview",
      "bundleIdentifier": "com.apple.Preview",
      "processID": 321
    }
  ]
}
```

The process-based ID is intentionally session-scoped. The Mac validates it
again when capture starts, so a terminated or relaunched process cannot be
mistaken for the originally selected source.

### Start capture

Display capture keeps the existing request:

`POST /api/v1/stream/start?layout=single&cursor=embedded`

Application capture adds the selected catalog ID:

`POST /api/v1/stream/start?layout=single&cursor=embedded&application=pid%3A321`

The response remains `MacStreamSession` version 1. This preserves the existing
workspace-window path and keeps older display-only clients compatible.

## Capture behavior

- ScreenCaptureKit uses an including-application content filter, which excludes
  other applications, the desktop, and the Dock.
- The capture is cropped to the union of the application's visible windows on
  the display containing the largest part of the application.
- Child windows are included.
- Application audio is carried by the existing session-audio channel.
- The system cursor is embedded for application capture. The virtual cursor API
  remains available only for display capture because application input routing
  is not yet implemented.
- If the application has windows on several displays, the first implementation
  captures the display with the greatest visible application area.

## Security boundary

- The Mac companion still requires macOS Screen Recording permission.
- The catalog contains only names, bundle identifiers, process IDs, and opaque
  session IDs; it does not expose document titles or window contents.
- Selecting an application does not create an input-injection channel.
- Network access remains local through the existing Bonjour service and HTTP
  transport.

## Follow-up work

1. Refresh crop geometry when application windows move, resize, open, or close.
2. Add application icons to the catalog through a bounded image endpoint.
3. Define an authenticated, capability-limited input protocol before enabling
   clicks and keyboard events in a shared application.
4. Support applications spread across multiple displays through multiple
   endpoints or a composed application canvas.
5. Add explicit Mac selection when more than one companion is discovered.
