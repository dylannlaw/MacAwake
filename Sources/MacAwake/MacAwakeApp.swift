import EventKit
import SwiftUI

@main
struct MacAwakeApp: App {
    @StateObject private var controller = AwakeController.shared

    init() {
        if CommandLine.arguments.contains("--self-test-battery") { runBatterySelfTest() }
        // Debug: `MacAwake --preview-panel` also shows the panel in a normal window, for screenshots.
        if CommandLine.arguments.contains("--preview-panel") {
            DispatchQueue.main.async { PreviewWindow.show() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(controller: controller)
        } label: {
            Image(systemName: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var controller: AwakeController
    @StateObject private var pickingDuration = Flag()
    @StateObject private var contentSize = SizeBox()
    @AppStorage("panel.showSettings") private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusHeader(controller: controller)

            ModeGrid(controller: controller, pickingDuration: $pickingDuration.on)

            if controller.mode == .timed {
                TimerCard(controller: controller)
            } else if pickingDuration.on {
                DurationPicker { minutes in
                    controller.startTimed(minutes: minutes)
                    pickingDuration.on = false
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !controller.hasAccess {
                AccessCard(controller: controller)
            } else {
                AgendaSection(controller: controller)
            }

            SettingsSection(controller: controller, expanded: $showSettings)

            Divider()
            Footer(controller: controller)
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .focusEffectDisabled()   // no blue focus ring on the first tile when the panel opens
        // The menu bar window grows with the content but never shrinks back on its own
        // (for example after the timer stops), leaving empty space. Measure and fit it.
        .background(GeometryReader { g in
            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(ContentHeightKey.self) { h in contentSize.height = h }
        .background(FitWindowToContent(height: contentSize.height))
        .animation(.snappy(duration: 0.2), value: controller.mode)
        .animation(.snappy(duration: 0.2), value: pickingDuration.on)
        .animation(.snappy(duration: 0.2), value: showSettings)
        .onChange(of: controller.mode) { _, m in if m == .timed { pickingDuration.on = false } }
    }
}

// MARK: - Status header

private struct StatusHeader: View {
    @ObservedObject var controller: AwakeController

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.18))
                Image(systemName: controller.menuBarSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: controller.isAwake && controller.mode != .alwaysOn)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let wake = controller.wakeLine {
                    Label(wake, systemImage: "alarm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var tint: Color {
        if case .batteryLow = controller.pauseReason { return .red }
        if controller.pauseReason != nil { return .yellow }
        switch controller.mode {
        case .off: return .secondary
        case .timed: return .indigo
        case .alwaysOn: return .orange
        case .auto: return controller.isAwake ? .green : .secondary
        }
    }

    private var title: String {
        if let r = controller.pauseReason { return "Paused: \(r.shortLabel)" }
        switch controller.mode {
        case .off: return "Sleeping normally"
        case .alwaysOn: return "Staying awake"
        case .timed: return "Awake on a timer"
        case .auto: return controller.isAwake ? "Awake for an event" : "Waiting for events"
        }
    }

    private var subtitle: String {
        if let r = controller.pauseReason {
            var text: String
            switch r {
            case .batteryLow(let pct):
                text = (pct.map { "Battery at \($0)%. " } ?? "Battery is low. ") + "Plug in to keep your Mac awake."
            case .onBattery: text = "On battery. Plug in to keep your Mac awake."
            case .lowPowerMode: text = "Low Power Mode is on. Plug in or turn it off to keep your Mac awake."
            }
            if controller.mode == .timed, let until = controller.timedUntil {
                text += " Timer still ends at \(until.formatted(date: .omitted, time: .shortened))."
            }
            return text
        }
        switch controller.mode {
        case .off: return "MacAwake is off. Your Mac sleeps as usual."
        case .alwaysOn: return "Until you change the mode."
        case .timed:
            guard let until = controller.timedUntil else { return "" }
            return "Until \(until.formatted(date: .omitted, time: .shortened)), then off."
        case .auto:
            if !controller.hasAccess { return "Needs calendar access." }
            if let e = controller.currentEvent, let until = controller.awakeUntil {
                return "\(e.title ?? "Event") · until \(until.formatted(date: .omitted, time: .shortened))"
            }
            if let next = controller.nextEvent {
                return "Next: \(next.title ?? "Event") · \(next.startDate.formatted(.relative(presentation: .named)))"
            }
            return "No events in the next 7 days."
        }
    }
}

// MARK: - Mode tiles

private struct ModeGrid: View {
    @ObservedObject var controller: AwakeController
    @Binding var pickingDuration: Bool

    var body: some View {
        HStack(spacing: 8) {
            tile("Calendar", "calendar", .auto, tint: .green)
            tile("Always", "cup.and.saucer.fill", .alwaysOn, tint: .orange)
            tile("Timer", "hourglass", .timed, tint: .indigo)
            tile("Off", "moon.zzz.fill", .off, tint: .gray)
        }
    }

    private func tile(_ title: String, _ symbol: String, _ mode: Mode, tint: Color) -> some View {
        let selected = controller.mode == mode || (mode == .timed && pickingDuration)
        return Button {
            if mode == .timed {
                // Choosing a timer needs a duration first; a running timer stays as it is.
                if controller.mode != .timed { pickingDuration.toggle() }
            } else {
                pickingDuration = false
                controller.mode = mode
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(selected ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.quaternary.opacity(0.6)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressableStyle())
        .help(mode.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Timer

private struct DurationPicker: View {
    var onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep awake for").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(timedDurations, id: \.self) { m in
                    Button(shortDuration(m)) { onPick(m) }
                        .buttonStyle(ChipStyle())
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.indigo.opacity(0.08)))
    }
}

private struct TimerCard: View {
    @ObservedObject var controller: AwakeController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let until = controller.timedUntil ?? context.date
            let start = controller.timedStart ?? context.date
            let total = max(1, until.timeIntervalSince(start))
            let left = max(0, until.timeIntervalSince(context.date))

            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.indigo.opacity(0.15), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: left / total)
                        .stroke(.indigo, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: left)
                    Image(systemName: "hourglass").foregroundStyle(.indigo)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 6) {
                    Text(countdown(left))
                        .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                    HStack(spacing: 6) {
                        Button("+30m") { controller.extendTimed(minutes: 30) }.buttonStyle(ChipStyle())
                        Button("+1h") { controller.extendTimed(minutes: 60) }.buttonStyle(ChipStyle())
                        Button("Stop") { controller.stopTimed() }.buttonStyle(ChipStyle(role: .destructive))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.indigo.opacity(0.08)))
    }

    private func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Agenda

private struct AgendaSection: View {
    @ObservedObject var controller: AwakeController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Coming up")
            if controller.agenda.isEmpty {
                Text("Nothing in the next 7 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(controller.agenda, id: \.calendarItemIdentifier) { e in
                    EventRow(event: e, ongoing: controller.isOngoing(e))
                }
            }
        }
        .opacity(controller.mode == .auto || controller.mode == .timed ? 1 : 0.55)
    }
}

private struct EventRow: View {
    let event: EKEvent
    let ongoing: Bool
    @StateObject private var hovering = Flag()

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(cgColor: event.calendar?.cgColor ?? CGColor(gray: 0.5, alpha: 1)))
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Event").font(.callout).lineLimit(1)
                Text(timeText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if ongoing {
                Text("Now")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.green.opacity(0.2)))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering.on ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering.on = $0 }
    }

    private var timeText: String {
        if event.isAllDay { return "All day · " + event.startDate.formatted(.dateTime.weekday().day().month()) }
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(event.startDate) { day = "Today" }
        else if cal.isDateInTomorrow(event.startDate) { day = "Tomorrow" }
        else { day = event.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(start) – \(end)"
    }
}

private struct AccessCard: View {
    @ObservedObject var controller: AwakeController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("MacAwake needs calendar access to follow your events.", systemImage: "calendar.badge.exclamationmark")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Grant Access") { controller.requestAccess() }.buttonStyle(.borderedProminent)
                Button("Open Settings…") { controller.openPrivacySettings() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.1)))
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    @ObservedObject var controller: AwakeController
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    SectionLabel("Settings")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    SettingToggle("Keep display on", "display", $controller.keepDisplayOn)
                    SettingToggle("Count all-day events", "sun.max", $controller.includeAllDay)
                    SettingToggle("Ignore events marked Free", "circle.dashed", $controller.ignoreFreeEvents)

                    HStack {
                        Label("Wake before", systemImage: "arrow.left.to.line").font(.callout)
                        Spacer()
                        Picker("", selection: $controller.leadMinutes) {
                            ForEach([0, 1, 2, 5, 10, 15], id: \.self) { m in
                                Text(m == 0 ? "At start" : "\(m) min").tag(m)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                    HStack {
                        Label("Stay awake after", systemImage: "arrow.right.to.line").font(.callout)
                        Spacer()
                        Picker("", selection: $controller.trailMinutes) {
                            ForEach([0, 1, 2, 5, 10, 15], id: \.self) { m in
                                Text(m == 0 ? "At end" : "\(m) min").tag(m)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }

                    if controller.powerState.hasBattery {
                        Divider()
                        HStack {
                            Label("Stop below", systemImage: "battery.25").font(.callout)
                            Spacer()
                            Picker("", selection: $controller.batteryStopPercent) {
                                ForEach([0, 10, 20, 30, 50], id: \.self) { p in
                                    Text(p == 0 ? "Never" : "\(p)%").tag(p)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                        .help("On battery, stop keeping your Mac awake once the charge drops below this. It resumes when you plug in.")
                        SettingToggle("Only when plugged in", "powerplug", $controller.onlyWhenPluggedIn)
                        SettingToggle("Pause in Low Power Mode", "leaf", $controller.pauseInLowPowerMode)
                    }

                    Divider()

                    if controller.wakeHelperInstalled {
                        SettingToggle("Wake Mac from sleep for events", "alarm", $controller.wakeForEvents)
                        if controller.wakeForEvents {
                            HStack {
                                Label("Check for new events", systemImage: "arrow.clockwise").font(.callout)
                                Spacer()
                                Picker("", selection: $controller.sleepCheckMinutes) {
                                    ForEach([0, 15, 30, 60], id: \.self) { m in
                                        Text(m == 0 ? "Never" : (m == 60 ? "Every hour" : "Every \(m) min")).tag(m)
                                    }
                                }
                                .labelsHidden().fixedSize()
                            }
                            .help("While the Mac sleeps, wake it briefly in the background (screen stays off) to look for events added since it went to sleep.")
                        }
                    } else {
                        HStack {
                            Label("Wake from sleep", systemImage: "alarm").font(.callout)
                            Spacer()
                            Button("Set Up…") { controller.installWakeHelper() }
                                .controlSize(.small)
                                .disabled(controller.wakeHelperBusy)
                        }
                    }

                    if let err = controller.wakeHelperError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    if controller.hasAccess && !controller.calendars.isEmpty {
                        DisclosureGroup {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(controller.calendars, id: \.calendarIdentifier) { cal in
                                        Toggle(isOn: controller.binding(for: cal)) {
                                            HStack(spacing: 6) {
                                                Circle().fill(Color(cgColor: cal.cgColor)).frame(width: 8, height: 8)
                                                Text(cal.title).lineLimit(1)
                                                Text(cal.source.title).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            .font(.callout)
                                        }
                                        .toggleStyle(.checkbox)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 150)
                        } label: {
                            Label("Calendars", systemImage: "calendar").font(.callout)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

private struct SettingToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    init(_ title: String, _ symbol: String, _ isOn: Binding<Bool>) {
        self.title = title
        self.symbol = symbol
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).font(.callout)
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }   // whole row is clickable
    }
}

// MARK: - Footer

private struct Footer: View {
    @ObservedObject var controller: AwakeController

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Launch at Login", isOn: $controller.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            if controller.wakeHelperInstalled {
                Menu {
                    Button("Remove Wake Helper…") { controller.uninstallWakeHelper() }
                        .disabled(controller.wakeHelperBusy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Refresh now")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
                .font(.caption)
        }
    }
}

// MARK: - Small pieces

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

/// Slight shrink on press, for the mode tiles.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small rounded pill button with a hover highlight.
private struct ChipStyle: ButtonStyle {
    var role: ButtonRole? = nil
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, destructive: role == .destructive)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyle.Configuration
        let destructive: Bool
        @StateObject private var hovering = Flag()

        var body: some View {
            configuration.label
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(minWidth: 44)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .background(
                    Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering.on ? 0.11 : 0.07))
                )
                .contentShape(Capsule())
                .onHover { hovering.on = $0 }
        }
    }
}

private func shortDuration(_ minutes: Int) -> String {
    minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
}

/// A bit of local view state. Used instead of @State, whose macro plugin the Command Line Tools don't ship.
final class Flag: ObservableObject {
    @Published var on = false
}

/// Debug-only window that hosts the panel (see `--preview-panel`).
@MainActor
enum PreviewWindow {
    private static var window: NSWindow?

    static func show() {
        let host = NSHostingController(rootView: PanelView(controller: AwakeController.shared)
            .background(Color(nsColor: .windowBackgroundColor)))
        let w = NSWindow(contentViewController: host)
        w.title = "MacAwake panel preview"
        w.styleMask = [.titled, .closable]
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w

        // `--snapshot <path.png>`: save the window's content to a PNG (no Screen Recording permission needed).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { snapshot(to: path) }
        }
    }

    static func snapshot(to path: String) {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Window fitting

final class SizeBox: ObservableObject {
    @Published var height: CGFloat = 0
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Resizes the hosting window to the panel's height, keeping its top edge where it is.
private struct FitWindowToContent: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let target = height
        DispatchQueue.main.async {
            guard target > 0, let window = view.window else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.height - target) > 0.5 else { return }
            let fitted = NSRect(x: content.minX, y: content.maxY - target, width: content.width, height: target)
            window.setFrame(window.frameRect(forContentRect: fitted), display: true)
        }
    }
}
