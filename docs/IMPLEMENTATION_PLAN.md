# MacAwake — Implementation Plan

## 1. Overview

MacAwake is a macOS menu bar app that keeps the Mac awake (like `caffeinate -di`) **only while a calendar event is on**, and lets it sleep normally the rest of the time.

**Goals**
- Prevent idle sleep automatically during calendar events (meetings, calls, presentations).
- Leave power management alone when no event is on.
- Run in the menu bar only, with no Dock icon and no main window.
- Need no setup beyond granting calendar access once.

**Non-goals (v1)**
- Preventing sleep when a MacBook lid is closed (this needs clamshell mode, the same as `caffeinate`). *Superseded by [Closed-lid keep-awake](changes/2026-11-24-closed-lid.md).*
- Talking to calendar provider APIs directly (Google or Microsoft Graph).
- Distribution through the Mac App Store or notarised releases.

## 2. Requirements

### Functional
| ID | Requirement |
|---|---|
| F1 | When an eligible event is on, prevent idle system sleep. |
| F2 | Optionally prevent display sleep as well (on by default). |
| F3 | When no eligible event is on, release all sleep assertions. |
| F4 | Eligible events exclude cancelled events, declined events and (by default) all-day events. |
| F5 | Optional filter to ignore events marked "Free". |
| F6 | Configurable buffer before the event starts (default 2 min) and after it ends (default 0 min). |
| F7 | Per-calendar include/exclude toggle. |
| F8 | Manual modes: **Auto**, **Always awake**, **Off**. |
| F9 | Menu shows the current state, the current event and when it ends, and the next event. |
| F10 | Optional launch at login. |

### Non-functional
- **Platform:** macOS 14 (Sonoma) or later, Apple Silicon and Intel.
- **Resource use:** negligible CPU (a 30 s timer with 5 s tolerance, plus event-driven updates).
- **Failure safety:** if the app quits or crashes, macOS releases its assertions automatically, so the Mac never gets stuck awake.
- **Privacy:** calendar data is read locally through EventKit. Nothing leaves the Mac.

## 3. Architecture

```
┌──────────────────────────────────────────────────────────┐
│ MacAwakeApp (SwiftUI App, MenuBarExtra)                  │
│   └── MenuContent (View) ── binds to ──┐                 │
│                                        ▼                 │
│ AwakeController (@MainActor ObservableObject)            │
│   ├── settings (UserDefaults-backed @Published)          │
│   ├── EKEventStore ── reads events/calendars             │
│   ├── refresh triggers: Timer · EKEventStoreChanged ·    │
│   │                     NSWorkspace.didWake              │
│   └── SleepAssertion ── IOKit power assertions           │
└──────────────────────────────────────────────────────────┘
```

### Key technology choices
| Concern | Choice | Rationale |
|---|---|---|
| UI | SwiftUI `MenuBarExtra` (`.menu` style) | Native menu bar UI with very little code (macOS 13+). |
| Calendar access | EventKit (`EKEventStore`) | Covers every account added to macOS Calendar (iCloud, Google, Exchange, CalDAV) without OAuth. |
| Keeping the Mac awake | `IOPMAssertionCreateWithName` | The same assertions `caffeinate` uses, without starting a child process. They're released automatically when the app exits. |
| Change detection | 30 s timer + `EKEventStoreChanged` + wake notification | Simple and robust. It catches event boundaries within about 30 s. |
| Persistence | `UserDefaults` | A few scalar settings don't need anything heavier. |
| Login item | `SMAppService.mainApp` | Modern API (macOS 13+) with no helper app. |
| Build | Swift Package Manager + `build.sh` bundling | No Xcode project needed, and the build is reproducible from the CLI. |

## 4. Project structure

```
MacAwake/
├── Package.swift                 # SPM manifest, macOS 14, one executable target
├── Info.plist                    # LSUIElement, calendar usage strings, bundle ID
├── build.sh                      # swift build → .app bundle → ad-hoc codesign
├── README.md                     # User-facing build/usage notes
├── docs/
│   └── IMPLEMENTATION_PLAN.md    # This document
└── Sources/MacAwake/
    ├── MacAwakeApp.swift         # @main App + MenuContent view
    ├── AwakeController.swift     # State, settings, calendar logic, refresh loop
    └── SleepAssertion.swift      # IOKit assertion wrapper
```

## 5. Component design

### 5.1 `SleepAssertion`
A thin wrapper around IOKit power assertions.

- `enable(reason:keepDisplayOn:)`
  - Creates `kIOPMAssertionTypePreventUserIdleSystemSleep` (the equivalent of `caffeinate -i`).
  - If `keepDisplayOn` is set, it also creates `kIOPMAssertionTypePreventUserIdleDisplaySleep` (the equivalent of `-d`).
  - It's **idempotent**: if it's already active with the same reason and display flag, it does nothing. This keeps the 30 s refresh from churning assertions.
- `disable()` releases both assertion IDs and resets them to 0.
- `deinit` calls `disable()`.

The event title is passed as the assertion reason, so `pmset -g assertions` shows *why* the Mac is awake.

### 5.2 `AwakeController`
The single source of truth, marked `@MainActor`.

**Published state:** `isAwake`, `currentEvent`, `awakeUntil`, `nextEvent`, `hasAccess`, `calendars`.

**Settings** (each is `@Published` with a `didSet` that saves to UserDefaults and calls `refresh()`):

| Key | Type | Default |
|---|---|---|
| `mode` | `Mode` (`auto` / `alwaysOn` / `off`) | `auto` |
| `keepDisplayOn` | Bool | `true` |
| `includeAllDay` | Bool | `false` |
| `ignoreFreeEvents` | Bool | `false` |
| `leadMinutes` | Int | `2` |
| `trailMinutes` | Int | `0` |
| `excludedCalendarIDs` | `Set<String>` | empty |

An **exclude** list is stored rather than an include list, so calendars added later are on by default.

**Lifecycle**
1. `init` loads the settings and starts the observers.
2. It checks `EKEventStore.authorizationStatus(for: .event)`:
   - `.fullAccess`: load calendars and refresh.
   - `.notDetermined`: call `requestFullAccessToEvents()`.
   - Anything else: show "Needs calendar access" with a button that opens the privacy settings.

**Refresh triggers**
- A `Timer` every 30 s (5 s tolerance).
- `.EKEventStoreChanged`: reload the calendars and refresh.
- `NSWorkspace.didWakeNotification`: refresh.
- Any change to a setting.

### 5.3 Core algorithm: `refresh()`

```
now = Date()
events = store.events(in [now − 24h, now + 24h], enabled calendars)
           .filter(isRelevant)
           .sorted(by: startDate)

window(e) = [e.start − lead, max(start, e.end + trail)]

active   = events where window(e) contains now
current  = active with the latest end      // handles overlapping events
upcoming = first event where window(e).start > now

shouldBeAwake =
  mode == .auto     → current != nil
  mode == .alwaysOn → true
  mode == .off      → false

shouldBeAwake ? assertion.enable(reason, keepDisplayOn) : assertion.disable()
```

**`isRelevant(event)` rejects an event when:**
- `status == .canceled`
- it's all-day and `includeAllDay` is off
- `ignoreFreeEvents` is on and `availability == .free`
- the current user's attendee `participantStatus == .declined`

**Back-to-back events:** each window is checked on its own. When one event ends exactly as the next begins (or the lead buffer overlaps the previous event), at least one window always contains `now`, so the Mac stays awake without a gap.

### 5.4 Menu UI (`MenuContent`)
```
☕  Awake — Daily Standup · until 10:30
    Next: 1:1 with Manager · Today, 14:00
    ─────────────
    ✓ Auto — follow calendar
      Always awake
      Off
    ─────────────
    ✓ Keep display on (not just the system)
      Count all-day events
      Ignore events marked "Free"
    Wake before event        ▸
    Stay awake after event   ▸
    Calendars                ▸   (per-calendar toggles, "Title · Account")
    ─────────────
      Launch at Login
    Refresh Now          ⌘R
    Quit MacAwake        ⌘Q
```

**Menu bar icon**
| State | SF Symbol |
|---|---|
| Keeping the Mac awake | `cup.and.saucer.fill` |
| Auto, idle | `cup.and.saucer` |
| Off | `moon.zzz` |

## 6. Packaging and permissions

**Info.plist essentials**
- `LSUIElement = true`: menu bar only, with no Dock icon.
- `NSCalendarsFullAccessUsageDescription` (macOS 14+) and `NSCalendarsUsageDescription` (older): without these, macOS terminates the app as soon as it asks for calendar access.
- `CFBundleIdentifier = local.macawake.app`, used by TCC to remember the permission.
- `LSMinimumSystemVersion = 14.0`.

**What `build.sh` does**
1. `swift build -c release`
2. Assembles `build/MacAwake.app/Contents/{MacOS,Info.plist}`.
3. Signs it ad hoc with `codesign --force --deep --sign -`.

**Sandbox / entitlements:** the app isn't sandboxed and doesn't use the hardened runtime, so it needs no calendar entitlement. If it later gets the hardened runtime (for notarisation), add `com.apple.security.personal-information.calendars`.

## 7. Implementation phases

| Phase | Scope | Done when |
|---|---|---|
| **1. Skeleton** | SPM package, `MenuBarExtra` with a static label, `Info.plist`, `build.sh` | The icon appears in the menu bar, with no Dock icon. |
| **2. Sleep assertions** | `SleepAssertion`; a temporary toggle in the menu | `pmset -g assertions` shows and clears the MacAwake assertions. |
| **3. Calendar access** | Permission flow, calendar list, privacy-settings fallback | The prompt appears and calendars are listed. |
| **4. Core logic** | `refresh()`, event filtering, buffers, the three refresh triggers | The assertion turns on and off around a test event within 30 s. |
| **5. Settings UI** | Modes, toggles, lead/trail pickers, calendar filter, persistence | Settings survive a relaunch. |
| **6. Polish** | Status and next-event text, state icons, launch at login, README | Works after reboot and login. |

## 8. Testing plan

### Manual test cases
| # | Scenario | Expected |
|---|---|---|
| T1 | Create an event starting in 3 min (lead 2 min) | Awake about 1 min from now, and the icon fills. |
| T2 | Event ends (trail 0) | Assertions released within 30 s. |
| T3 | Two overlapping events | "until" shows the later end time, with no gap. |
| T4 | Back-to-back events (10:00–10:30, 10:30–11:00) | Stays awake throughout. |
| T5 | Decline an invite | That event is ignored. |
| T6 | All-day event, default settings | Ignored. With the toggle on, it keeps the Mac awake all day. |
| T7 | Event marked Free, filter on | Ignored. |
| T8 | Exclude a calendar | Its events are ignored, and the setting persists after a relaunch. |
| T9 | Edit an event time in Calendar.app | The state updates almost immediately (`EKEventStoreChanged`). |
| T10 | Sleep the Mac manually, then wake it mid-event | The state re-evaluates on wake. |
| T11 | Mode Off during an event | Assertions released. |
| T12 | Mode Always awake with no events | Assertions held. |
| T13 | Force-quit the app while awake | `pmset` shows no MacAwake assertions. |
| T14 | Deny calendar access | Shows "Needs calendar access" and the settings button works. |
| T15 | Toggle "Keep display on" while awake | The display assertion is added or removed, and the system assertion stays. |

### Verification command
```bash
pmset -g assertions | grep -i macawake -A1
# or watch the event title as the reason:
pmset -g assertions | grep -i "Calendar event"
```

### Optional unit tests
Pull `isRelevant` and `window(for:)` out into pure functions that take a plain struct instead of `EKEvent`, then test the buffers, overlap and boundary conditions with XCTest.

## 9. Known limitations and risks

| Item | Impact | Mitigation |
|---|---|---|
| Ad-hoc signing changes on every rebuild | Calendar permission may be asked for again | `tccutil reset Calendar local.macawake.app`. Use a Developer ID later. |
| Closing a MacBook lid still sleeps it | Expected behaviour | Document it. Clamshell mode needs power and an external display. |
| Up to 30 s delay at event boundaries | Minor | Use a lead buffer of 1 min or more. See the future improvement below. |
| Google calendar sync delay in macOS | Events added on another device may show up late | Out of scope: it depends on the account's fetch interval in Calendar. |
| `SMAppService` can fail when the app isn't in /Applications | Launch at login doesn't stick | Install to /Applications. The error is logged. |

## 10. Future improvements
- **Exact boundary scheduling:** replace the 30 s poll with a one-shot timer set to the next window start or end (keep a slow fallback poll).
- **Keyword rules:** only count events whose title or notes match a pattern (for example "Zoom", "Meet", "Teams"), or that have a video-call URL.
- **"Stay awake for…" quick actions:** 30 min, 1 h or 2 h, like Amphetamine or KeepingYouAwake.
- **Battery guard:** pause below a set battery percentage when not plugged in.
- **Notifications:** tell the user when awake mode starts or ends.
- **Distribution:** a Developer ID signature, notarisation, hardened runtime with the calendar entitlement, and a DMG or Homebrew cask.
- **Universal binary:** `swift build --arch arm64 --arch x86_64` combined with `lipo`.
