# iOS XREAL private HID experiment

This debug-only experiment probes whether iOS exposes the XREAL Air v1 vendor
HID interfaces to a normally signed iPhone application while the glasses are
also connected as a DisplayPort external display.

## Scope

- Dynamically loads the private `IOHIDManager` and `IOHIDDevice` C symbols.
- Enumerates every HID service visible to the app and records its vendor,
  product, usage page, usage, product name, and transport.
- Opens every interface with XREAL USB vendor `0x3318`, including unexpected
  product IDs. The known XREAL Air v1 product ID is `0x0424`.
- Requests factory calibration and enables IMU reports.
- Decodes gyroscope and accelerometer samples into the existing `HeadPose`
  stream.
- Prefers XREAL pose when it becomes active and otherwise keeps the public
  AirPods fallback.

The experiment is compiled only in Debug builds. Release builds do not contain
the private IOHID loader or symbol names.

## Device test

1. Build and run the `ExtendReality` scheme on a physical USB-C iPhone.
2. Keep the Xcode console visible and filter for `XREALPrivateHID`.
3. Start the app before connecting the XREAL Air.
4. Connect the glasses directly over USB-C.
5. Open ExtendReality's head-tracking readout.
6. Copy the monospaced diagnostic block under **Tracking**. The same device
   list is logged under the `XREALPrivateHID` category.

Expected checkpoints:

1. `Private IOHID manager opened`
2. `HID probe: <VID>:<PID> usage <page>/<usage> ...`
3. `XREAL HID opened`
4. `XREAL calibration loaded`
5. `XREAL private USB 3DoF is active`

The first failing checkpoint identifies the iOS boundary:

- Missing symbols: the private framework is unavailable.
- `0 HID services enumerated`: iOS allows the manager but hides all HID
  services from the app.
- Other devices appear but no `3318:*`: iOS doesn't publish the XREAL vendor
  HID service, or the connected glasses use another vendor ID.
- `IOHIDDeviceOpen` failure: the service exists but the sandbox blocks access.
- `IOHIDDeviceSetReport` failure: input may be visible, but iOS blocks the
  control reports needed to start the IMU.

Disable the probe without changing code by adding the launch argument:

```text
-XREALPrivateHIDEnabled NO
```

This is not an App Store-compatible implementation and must remain isolated
from Release builds.
