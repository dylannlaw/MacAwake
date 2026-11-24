# Battery settings by kind of Mac

## Summary

MacAwake now detects whether it runs on a MacBook or a desktop Mac (Mac mini, Mac Studio, iMac, Mac Pro) and shows the battery settings to match. MacBooks always get **Stop below**, **Only when plugged in**, **Pause in Low Power Mode** and **Keep awake with lid closed**. Desktops hide them, unless a UPS is attached: then the three battery settings appear, worded for the UPS ("Stop below (UPS)", "Only on mains power"), and the paused message talks about the UPS and mains power.

## Why

Requested: the panel should offer battery settings based on the kind of Mac. Before this, visibility depended only on what the power-source API reported at that moment: the Battery block on "battery or UPS present", and the lid setting on "internal battery present". A MacBook whose battery reading failed lost its settings, the demo had to pretend to have a battery, and a desktop on a UPS saw MacBook wording ("Plug in to keep your Mac awake").

## Design

- **Detection** (`DeviceKind.current`, read once at launch), first match wins:
  1. Device-tree `IODeviceTree:/product` `product-name` on Apple silicon ("MacBook Air (M2, 2022)", "Mac mini (M6)"). Needed because Apple silicon `hw.model` is just "Mac14,2" for laptops and desktops alike.
  2. `hw.model` on Intel ("MacBookPro16,1", "Macmini8,1", "iMac20,1", "MacPro7,1").
  3. Hardware: `AppleClamshellState` on `IOPMrootDomain` (only Macs with a lid have it) or a present internal battery → laptop; otherwise desktop.
- **Which settings** (`BatterySettingsStyle.for(_:power:)`): laptop → `.battery`, always; desktop → `.ups` while `PowerState.hasBattery` (a UPS), else none. **Keep awake with lid closed** shows on laptops only (or with `--preview-lid-status`).
- **Rules unchanged.** The safeguard rules don't look at the kind of Mac; a desktop without a UPS is never on battery, so nothing ever blocks. Only what's shown and how it's worded changes.
- **Testing hooks:** `MACAWAKE_FAKE_DEVICE=laptop|desktop`. `--demo` counts as a laptop by default (so the screenshots show every setting, as before). A demo's made-up power (from main's `--demo battery`) applies to laptops only; a desktop demo has no battery unless `MACAWAKE_FAKE_POWER` is set, which overrides both, so a desktop on a UPS can be previewed without touching real settings. `--self-test-battery` gained 13 cases for detection and settings choice, and prints what it detects for this Mac.

**Options considered and not picked**
- *`hw.model` alone:* doesn't distinguish Apple silicon laptops from desktops.
- *`system_profiler SPHardwareDataType`:* gives "Model Name" but takes about a second and spawns a process.
- *Internal battery alone (the old rule):* this Mac mini reports an `AppleSmartBattery` service with `BatteryInstalled = No`, so service presence is unreliable; and a MacBook should keep its settings even when the reading fails.
- *A manual "show battery settings" switch:* not needed once detection is reliable, and one more setting to explain.

## Files

- `Sources/MacAwake/DeviceKind.swift` (new): `DeviceKind`, `BatterySettingsStyle`, `DeviceInfo` readers.
- `Sources/MacAwake/AwakeController.swift`: `device`, `batterySettings`, `showsLidSetting` (replaces `hasBattery`); demo reads faked power.
- `Sources/MacAwake/MacAwakeApp.swift`: `BatterySettings` view with UPS wording; UPS paused subtitles on desktops.
- `Sources/MacAwake/PowerSource.swift`: self-test cases.
- `scripts/screenshots.sh`: new crop offset for `wake.png` (the Battery block now shows in the demo).
- `docs/screenshots/*`, `docs/features/settings.md`, `README.md`, `TECHNICAL.md`, `docs/README.md`, a superseded-in-part line on the battery-safeguards note.

## Verified / not verified

- ✅ `./build.sh` builds with no errors or new warnings.
- ✅ `--self-test-battery`: all 25 cases pass; on this Mac it prints "desktop (Mac mini (M6))".
- ✅ Snapshots with `--demo calendar` and Settings open: laptop shows Stop below / Only when plugged in / Pause in Low Power Mode and Keep awake with lid closed; desktop shows none of them; desktop + `MACAWAKE_FAKE_POWER=ac:100` shows "Stop below (UPS)", "Only on mains power", Pause in Low Power Mode, and no lid setting.
- ✅ Retook every screenshot with `./scripts/screenshots.sh` and checked `settings.png` and `wake.png`.
- ❌ Not run on a real MacBook (Apple silicon or Intel), an Intel desktop, or with a real UPS. Detection on those relies on the documented device-tree name and model prefixes.
- ❌ The UPS paused subtitle wasn't snapshotted (the demo doesn't run the safeguard rules).

## Follow-ups

- Check detection on a MacBook and an Intel Mac; `--self-test-battery` prints the result.
