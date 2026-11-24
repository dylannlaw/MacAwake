# Plan: battery safeguards

Status: **approved and built**. See the [change note](../changes/2026-11-24-battery-safeguards.md). Gap #2 in the competitor gap analysis (2026-11-24). Amphetamine and KeepingYouAwake both have this.

## Goal

Stop MacAwake from draining a MacBook flat. It covers three things:

1. Stop keeping awake when the battery falls below a level you choose.
2. Optionally keep awake only while plugged in.
3. Optionally pause while Low Power Mode is on.

Closed-lid mode (gap #1, another session) will reuse the same check, so it has to be one small, clearly named API.

## Behaviour

The safeguard is a **veto** applied after the mode has decided. `refresh()` first works out `shouldBeAwake` as it does today, then asks the power check. If the check blocks, the assertions are released and the panel shows "Paused". The mode itself doesn't change.

| Mode | While paused | When the block clears |
|---|---|---|
| Calendar | The event doesn't keep the Mac awake | Resumes if the event is still on |
| Always | Stays in Always, but doesn't hold the Mac awake | Resumes |
| Timer | **Keeps counting down**, then ends in Off as usual | Resumes for the time that's left |
| Off | No effect | — |

Why Timer and Always get overridden too: a safeguard that a mode can skip isn't a safeguard. And "Always" with a dying battery ends in an unexpected sleep anyway. Pausing doesn't extend the timer. A timer is "until 3 PM", not "90 minutes of awake time", which matches how it's shown ("Until 15:00, then off").

**The battery level only matters on battery power.** Plugged in, the battery is charging, so a low level never blocks.

**Hysteresis:** on battery, the level only goes down. So once the level blocks, it **stays blocked until power is connected**. It doesn't resume at threshold + 1 % from a noisy reading. This latch is cleared by any switch to AC (or UPS → AC). Without it, readings near 20 % ↔ 21 % could make the Mac flap between awake and asleep.

### Wake scheduling while paused

- **Check-in wakes** (every 15 min while asleep) are skipped while the safeguard blocks. Each one costs battery, and nothing could be kept awake anyway.
- **Event wakes** are still scheduled. It's one wake per event, and you may have plugged in by then. On wake, `refresh()` decides again. If still blocked, the Mac goes back to sleep. This also covers "plugged in while asleep".

## Settings (`UserDefaults`, `@Published` in `AwakeController`)

| Key | Type | Default | UI |
|---|---|---|---|
| `batteryStopPercent` | Int | **10** | Picker "Stop below": Never, 10 %, 20 %, 30 %, 50 % |
| `onlyWhenPluggedIn` | Bool | **false** | Toggle "Only when plugged in" |
| `pauseInLowPowerMode` | Bool | **false** | Toggle "Pause in Low Power Mode" |

Why these defaults:
- 10 % is on by default because it's a safety net nearly nobody would object to. macOS already gets aggressive below about 10 %, and sleeping there protects the agent's work better than a dead battery does.
- The other two change behaviour noticeably, so they're opt-in.
- Low Power Mode only counts **while on battery**. macOS lets you set Low Power Mode to "Always", and respecting it on AC would silently break MacAwake on desktops.

The settings sit in a new **Battery** block in Settings, below the event buffers. It's hidden on Macs with no battery and no UPS (most desktops), where none of it applies.

## Code

### New file `Sources/MacAwake/PowerSource.swift` (about 80 lines)

```swift
/// A snapshot of how the Mac is powered.
struct PowerState: Equatable {
    var onBattery: Bool          // providing source is battery or UPS, not AC
    var percent: Int?            // internal battery (else UPS), nil if none
    var hasBattery: Bool         // internal battery or UPS present
    var lowPowerMode: Bool       // ProcessInfo.isLowPowerModeEnabled
}

/// Reads PowerState and calls back when it changes.
final class PowerSource {
    init(onChange: @escaping () -> Void)
    func current() -> PowerState
}
```

- **Reading:** `IOPSCopyPowerSourcesInfo` and `IOPSCopyPowerSourcesList`, then for each source `IOPSGetPowerSourceDescription`. Read `kIOPSTypeKey` (`InternalBattery` / `UPS`), `kIOPSCurrentCapacityKey` and `kIOPSMaxCapacityKey` to get the percent, and `kIOPSIsPresentKey`. The providing source comes from `IOPSGetProvidingPowerSourceType`: anything other than `kIOPMACPowerKey` means on battery.
- **Changes:**
  - `IOPSNotificationCreateRunLoopSource` on the main run loop. It fires on plug/unplug and about every 1 % change.
  - `NSProcessInfoPowerStateDidChange` for Low Power Mode.
  - Both call `onChange`, which runs `refresh()`. No new timer: the 30 s refresh is still the backstop.
- **Fake source for testing only:** if the environment variable `MACAWAKE_FAKE_POWER` is set (for example `battery:8`, `battery:50,lpm`, `ac:5`, `none`), `current()` returns that instead. Nothing in the UI exposes it. It lets the paused state be snapshotted and tested without draining a battery. `open --env MACAWAKE_FAKE_POWER=battery:8 …` passes it through.

### `AwakeController` changes (kept small)

- Three new settings, with `didSet` → save + `refresh()`, following the existing pattern.
- `@Published private(set) var power: PowerState`
- `@Published private(set) var pauseReason: PauseReason?`, with `enum PauseReason { case batteryLow(Int), onBattery, lowPowerMode }`
- A private latch, `batteryLatched: Bool`.
- **The reusable check for gap #1:**
  ```swift
  /// False when a battery safeguard says the Mac shouldn't be kept awake right now.
  /// Closed-lid mode and any future keep-awake path must check this.
  var batteryAllowsAwake: Bool { pauseReason == nil }
  ```
  Plus a pure `static func pauseReason(for: PowerState, stopPercent:, onlyPluggedIn:, respectLPM:, latched:) -> PauseReason?`. This makes the rule testable, and the closed-lid code can call it without depending on UI state.
- **In `refresh()`:** after the `switch mode` block:
  ```swift
  power = powerSource.current()
  pauseReason = shouldBeAwake ? evaluateSafeguards(power) : nil
  let holdAwake = shouldBeAwake && pauseReason == nil
  ```
  Then use `holdAwake` where `shouldBeAwake` is used now. `isAwake` reflects `holdAwake`. Check-ins also require `pauseReason == nil`. The latch is updated in `evaluateSafeguards`. The latch is checked even when `shouldBeAwake` is false (Calendar idle), so it doesn't miss the drop.
- **Existing quirk to keep in mind:** when a block clears in Calendar mode during an event, `!isAwake && mode == .auto` calls `declareUserActivity`, which turns the display on. That's fine when you've just plugged in, so it stays as is.

### `MacAwakeApp.swift` changes

- **Status header**, when `pauseReason != nil`:
  - title **"Paused: battery low"** / **"Paused: on battery"** / **"Paused: Low Power Mode"**
  - subtitle, for example "Battery at 9 %. Plug in to keep your Mac awake." For a timer, it adds "Timer still ends at 15:00."
  - tint `.red` for low battery, `.yellow` for the other two
- **Menu bar icon** while paused: `battery.25`.
- **Settings › Battery** block: as above, only when `power.hasBattery`.
- `menuBarSymbol`/`statusLine` in the controller get the paused case first.

## Edge cases

- **Desktop with no battery:** `hasBattery == false` and `onBattery == false`, so it never blocks and the section is hidden.
- **Desktop on a UPS during a power cut:** it counts as on battery. The UPS percent is used if it's reported. That's reasonable: don't hold a Mac awake on UPS power.
- **Battery not reporting a percent** (rare, or a fresh boot): no level block, but the plugged-in and Low Power Mode rules still apply.
- **The threshold changed while latched:** re-evaluate. Raising "Stop below" can latch straight away. Lowering it or choosing Never clears the latch if the level is now above the threshold. The latch exists to stop flapping from readings, not to override a change you made yourself.
- **Battery "never" setting:** no level rule at all.
- **Dark wake for an event on low battery:** `refresh()` blocks, no assertion is taken, and macOS sleeps again. No `declareUserActivity` happens, because that's only called when actually holding awake.
- **Relaunch while paused:** state comes from the live power reading. The latch isn't saved; after a relaunch on battery below the threshold, the level rule blocks again anyway.

## Test plan

1. `./build.sh` with no errors.
2. **Pure-rule checks:** a tiny debug entry point (`MacAwake --self-test-battery`, which prints and exits) runs `pauseReason(for:…)` over a table: AC at 5 % → nil; battery at 9 % with stop at 10 → batteryLow; battery at 50 % plus Low Power Mode with respect on → lowPowerMode; with respect off → nil; plugged-in rule on battery → onBattery; latched at 12 % → batteryLow; never + latched → nil; no battery → nil. *(Alternative if you'd rather not ship a debug flag: run the same table once in a scratch script and drop it.)*
3. **Panel snapshots**, with `MACAWAKE_FAKE_POWER` and `defaults write local.macawake.app mode alwaysOn`: battery:8 → "Paused: battery low"; battery:50,lpm with the Low Power Mode toggle on → "Paused: Low Power Mode"; ac:5 → normal "Staying awake"; none → Battery section hidden. Restore my `mode` and the new keys afterwards.
4. **Assertions:** with the fake battery:8 in Always mode, `pmset -g assertions | grep -i macawake` shows nothing. With ac:50, it shows the assertion.
5. **Real hardware (if on a MacBook):** set "Only when plugged in", unplug, and confirm the panel shows "Paused: on battery" and the assertion disappears within a second or two (the notification, not the 30 s poll). Plug back in and it resumes.
6. **Not testable here:** a real slow drain to 10 % overnight, and a UPS. These will be listed as not verified in the change note.

## Docs

- `README.md`: one plain-language bullet under Settings ("Stop keeping your Mac awake when the battery is low, or when unplugged, or in Low Power Mode") and a line in "Good to know".
- `TECHNICAL.md`: settings reference rows with defaults, a "Battery safeguards" paragraph under How it works (veto, latch, wake rules), and the `MACAWAKE_FAKE_POWER` testing hook.
- `docs/changes/2026-11-24-battery-safeguards.md` plus an index line. It names `batteryAllowsAwake` / `AwakeController.pauseReason(for:…)` for the closed-lid session.

## Options considered and not picked

- **Switching the mode to Off when the battery is low.** You'd lose Calendar mode without noticing and have to remember to switch back. That's the same objection as the early timer note. A pause that clears on its own is less surprising.
- **Fixed hysteresis (resume at threshold + 5 %).** On battery the level doesn't rise, so it would mean the same as "until plugged in" but harder to explain.
- **Pausing the timer's countdown while blocked.** It makes "Until 15:00" wrong. The timer is a clock time.
- **Respecting Low Power Mode on AC as well.** It breaks desktops that have Low Power Mode set to Always.
- **Polling the battery from a separate timer.** That's against the "`refresh()` is the one place" rule. The IOKit notification plus the existing 30 s refresh is enough.

## Open questions for you

1. Default for **Stop below**: 10 % (proposed), 20 %, or Never (off until you turn it on)?
2. OK to ship the hidden `MACAWAKE_FAKE_POWER` environment variable and a `--self-test-battery` flag, as `--preview-panel` is now? Or do the rule checks in a throwaway script only?
