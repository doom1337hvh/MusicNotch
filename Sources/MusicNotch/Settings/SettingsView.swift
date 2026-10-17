import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// The "Launch at login" switch. A class rather than `@State`, because the
/// Command Line Tools don't ship the plugin for SwiftUI's `@State` macro.
@Observable @MainActor
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isEnabled: Bool {
        get { status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            status = SMAppService.mainApp.status
        }
    }
}

/// Whether MusicNotch may see the Dock's swipe gestures (Input Monitoring), for "Hide while swiping".
@Observable @MainActor
final class SwipePermission {
    private(set) var isAllowed = SwipeMonitor.hasPermission

    func refresh() {
        isAllowed = SwipeMonitor.hasPermission
    }

    func request() {
        SwipeMonitor.requestPermission()
        refresh()
    }

    func openSystemSettings() {
        SwipeMonitor.openPermissionSettings()
    }
}

/// Creates the Settings window when it's opened and releases it when it's closed. It has a
/// tab per topic in its toolbar, like most Mac apps' settings, and fits each tab's height.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    var onBecameKey: (() -> Void)?
    private let prefs: Preferences
    private let adapter: AdapterProcess
    private let hotkeys: HotkeyCenter
    private let recorder: ShortcutRecorder
    private let swipePermission = SwipePermission()
    private var window: NSWindow?

    init(prefs: Preferences, adapter: AdapterProcess, hotkeys: HotkeyCenter) {
        self.prefs = prefs
        self.adapter = adapter
        self.hotkeys = hotkeys
        recorder = ShortcutRecorder(prefs: prefs, hotkeys: hotkeys)
    }

    func show() {
        if window == nil {
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(Self.tab("General", symbol: "gearshape",
                                         GeneralSettings(prefs: prefs, loginItem: LoginItem())))
            tabs.addTabViewItem(Self.tab("Notch", symbol: "rectangle.topthird.inset.filled",
                                         NotchSettings(prefs: prefs)))
            tabs.addTabViewItem(Self.tab("Animations", symbol: "sparkles",
                                         AnimationSettings(prefs: prefs, swipePermission: swipePermission)))
            tabs.addTabViewItem(Self.tab("Shortcuts", symbol: "keyboard",
                                         ShortcutSettings(prefs: prefs, hotkeys: hotkeys, recorder: recorder)))
            tabs.addTabViewItem(Self.tab("Performance", symbol: "leaf", PerformanceSettings(prefs: prefs)))
            tabs.addTabViewItem(Self.tab("About", symbol: "info.circle", AboutSettings(adapter: adapter)))
            tabs.selectLastTab()

            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private static func tab<Content: View>(_ title: String, symbol: String, _ content: Content) -> NSTabViewItem {
        let host = NSHostingController(rootView: content)
        // The window takes each tab's own height.
        host.sizingOptions = [.preferredContentSize]
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    /// Switches to a tab, for a demo clip (`DemoScene`).
    func selectTab(_ index: Int) {
        (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = index
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stop()
        window = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        recorder.stop()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        swipePermission.refresh()
        onBecameKey?()
    }
}

/// Reopens on the tab used last.
private final class SettingsTabs: NSTabViewController {
    private static let lastTabKey = "settingsTab"
    private var isRestoring = false

    func selectLastTab() {
        isRestoring = true
        selectedTabViewItemIndex = min(max(UserDefaults.standard.integer(forKey: Self.lastTabKey), 0),
                                       tabViewItems.count - 1)
        isRestoring = false
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        // A demo clip (`DemoScene`) switches tabs itself; that isn't the user's choice.
        if !isRestoring && DemoScene.current == nil {
            UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.lastTabKey)
        }
    }
}

/// One tab's form, as tall as its contents.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form(content: content)
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Bindable var prefs: Preferences
    @Bindable var loginItem: LoginItem

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Launch at login", isOn: $loginItem.isEnabled)
                if loginItem.status == .requiresApproval {
                    LabeledContent("Needs your approval in System Settings.") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .foregroundStyle(.secondary)
                }
                if let error = loginItem.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle(isOn: $prefs.showMenuBarIcon) {
                    Text("Show menu bar icon")
                    if !prefs.showMenuBarIcon {
                        Text("To get back here, open MusicNotch again or right-click the notch.")
                    }
                }
            }

            Section("Where it appears") {
                Toggle(isOn: $prefs.showOnExternalDisplays) {
                    Text("Show on displays without a notch")
                    Text("Adds a small pill at the top center of external displays.")
                }
                Picker(selection: $prefs.hideInFullScreen) {
                    ForEach(FullScreenHiding.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Hide in full screen")
                    Text("\"When the playing app is\" hides it for a full-screen video, but not while music plays behind another full-screen app.")
                }
            }
        }
    }
}

private struct NotchSettings: View {
    @Bindable var prefs: Preferences

    var body: some View {
        SettingsPane {
            Section("When closed") {
                Toggle(isOn: $prefs.showBesideNotch) {
                    Text("Show artwork and bars beside the notch")
                    Text("When off, nothing shows until you hover over the notch, and the equalizer uses no power.")
                }
                Toggle(isOn: $prefs.showTrackPeek) {
                    Text("Show new tracks")
                    Text("When the song changes, the notch briefly opens to show it.")
                }
            }

            Section("Opening") {
                Picker(selection: $prefs.notchStyle) {
                    ForEach(NotchStyle.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Style")
                    Text("Minimal widens the notch with skip buttons. Compact and Full open a panel.")
                }
                Picker(selection: $prefs.openTrigger) {
                    ForEach(NotchOpenTrigger.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Open on")
                    Text("Click keeps it from opening as you reach for menu bar items nearby.")
                }
                Toggle(isOn: $prefs.openFromCameraOnly) {
                    Text("Only open from the camera")
                    Text("The closed notch's sides let the pointer through to the menu bar.")
                }
            }

            Section {
                Picker(selection: prefs.isLowResource ? .constant(.black) : $prefs.theme) {
                    ForEach(NotchTheme.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Theme")
                    Text("Glass lets the desktop show through below the camera, fading from black at the top.")
                }
                .disabled(prefs.isLowResource)
                Toggle(isOn: effective(\.showArtwork)) {
                    Text("Album artwork")
                    Text("When off, artwork isn't loaded at all.")
                }
                .disabled(prefs.isLowResource)
                Toggle(isOn: prefs.effectiveArtwork ? $prefs.tintWithArtwork : .constant(false)) {
                    Text("Colours from the artwork")
                    Text("Tints the equalizer, progress bar and volume slider with the album's colour.")
                }
                .disabled(!prefs.effectiveArtwork)
                Toggle(isOn: effective(\.showProgressBar)) {
                    Text("Progress bar")
                    Text("Drag it to skip through the song. Updates once a second, only while open.")
                }
                .disabled(prefs.isLowResource)
                Toggle(isOn: $prefs.showShuffleRepeat) {
                    Text("Shuffle and repeat buttons")
                    Text("For Spotify and Music. The first click asks to let MusicNotch control the app.")
                }
                Toggle(isOn: $prefs.showSearch) {
                    Text("Search button")
                    Text("Searches your Music library right in the notch, or sends a search to Spotify, YouTube or SoundCloud.")
                }
                Toggle("Click the artwork to open the playing app", isOn: $prefs.clickArtworkOpensApp)
            } header: {
                Text("In the open notch")
            } footer: {
                if prefs.isLowResource {
                    LowResourceNote(text: "Low-resource mode turns off glass, the artwork and the progress bar.")
                }
            }
        }
    }

    /// While low-resource mode is on, a switch shows as off and can't be changed.
    private func effective(_ keyPath: ReferenceWritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        prefs.isLowResource ? .constant(false) : $prefs[dynamicMember: keyPath]
    }
}

private struct AnimationSettings: View {
    @Bindable var prefs: Preferences
    let swipePermission: SwipePermission

    var body: some View {
        SettingsPane {
            Section {
                Picker(selection: prefs.isLowResource ? .constant(.instant) : $prefs.openAnimation) {
                    ForEach(OpenAnimation.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Open animation")
                    Text("How the notch opens and closes.")
                }
                .disabled(prefs.isLowResource)
            }

            Section {
                Picker(selection: prefs.isLowResource ? .constant(.none) : $prefs.spaceSwitchAnimation) {
                    ForEach(SpaceSwitchAnimation.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Appear on the new desktop")
                    Text("Fade fades the whole notch in. Slide also brings the artwork and bars in from the side the new desktop came from.")
                }
                .disabled(prefs.isLowResource)
                Toggle(isOn: hideDuringSwipes) {
                    Text("Hide while swiping")
                    Text("Hides the notch as soon as a swipe starts, instead of letting it leave with the old desktop. Needs the Input Monitoring permission; MusicNotch only listens for the Dock's swipe gesture.")
                }
                if prefs.hideDuringSwipes && !swipePermission.isAllowed {
                    LabeledContent {
                        Button("Open System Settings") { swipePermission.openSystemSettings() }
                    } label: {
                        Text("\(Image(systemName: "exclamationmark.triangle.fill")) Needs Input Monitoring")
                            .foregroundStyle(.orange)
                        Text("In Input Monitoring, remove MusicNotch if it's listed, then add it again with + and turn it on.")
                    }
                }
            } header: {
                Text("Switching desktops")
            } footer: {
                if prefs.isLowResource {
                    LowResourceNote(text: "Low-resource mode turns the animations off.")
                }
            }
        }
    }

    /// Turning it on asks for Input Monitoring the first time.
    private var hideDuringSwipes: Binding<Bool> {
        Binding {
            prefs.hideDuringSwipes
        } set: { enabled in
            if enabled && !swipePermission.isAllowed { swipePermission.request() }
            prefs.hideDuringSwipes = enabled
        }
    }
}

private struct ShortcutSettings: View {
    @Bindable var prefs: Preferences
    let hotkeys: HotkeyCenter
    let recorder: ShortcutRecorder

    var body: some View {
        SettingsPane {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.label) {
                        ShortcutField(action: action, hotkey: prefs.hotkeys[action],
                                      isUnavailable: hotkeys.unavailable.contains(action), recorder: recorder)
                    }
                }
                if let hint = recorder.hint, recorder.recording != nil {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Shortcuts work in any app. Click a field, then press the keys; Delete clears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct PerformanceSettings: View {
    @Bindable var prefs: Preferences

    var body: some View {
        SettingsPane {
            Section {
                Toggle(isOn: $prefs.lowResourceMode) {
                    Text("Low-resource mode")
                    Text("The lowest power use in one switch: turns off the animations, glass, artwork and progress bar, and batches updates once a second.")
                }
                Toggle(isOn: $prefs.followLowPowerMode) {
                    Text("Turn on with Low Power Mode")
                    Text("While macOS's Low Power Mode is on, so is low-resource mode.")
                }
                .disabled(prefs.lowResourceMode)
            } footer: {
                if prefs.isLowResourceForLowPowerMode {
                    LowResourceNote(text: "Low Power Mode is on, so low-resource mode is too.")
                }
            }

            Section {
                Picker(selection: prefs.isLowResource ? .constant(.never) : $prefs.equalizerAnimation) {
                    ForEach(EqualizerAnimation.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Equalizer animation")
                    Text("The moving bars are the only thing that uses power continuously. Otherwise they stay still.")
                }
                Picker(selection: prefs.isLowResource ? .constant(.batterySaver) : $prefs.updateBatching) {
                    ForEach(UpdateBatching.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Update batching")
                    Text("Groups bursts of track changes into fewer updates.")
                }
            }
            .disabled(prefs.isLowResource)
        }
    }
}

private struct AboutSettings: View {
    let adapter: AdapterProcess

    var body: some View {
        SettingsPane {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MusicNotch").font(.title3.weight(.semibold))
                        Text("Version \(Self.info("CFBundleShortVersionString") ?? "–")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("GitHub", destination: URL(string: "https://github.com/doom1337hvh/MusicNotch")!)
                }
                .padding(.vertical, 2)
                LabeledContent("Media adapter", value: adapterStatus)
            }

            Section("Licences") {
                LabeledContent("MusicNotch is free software under the MIT License.") {
                    Button("View") { Self.openResource("LICENSE") }
                }
                LabeledContent("Uses mediaremote-adapter by Jonas van den Berg, under the BSD 3-Clause License.") {
                    Button("View") { Self.openResource("mediaremote-adapter-LICENSE") }
                }
            }
        }
    }

    private var adapterStatus: String {
        // A demo clip (`DemoScene`) never starts the adapter.
        if DemoScene.current != nil { return "Working" }
        return switch adapter.status {
        case .failed(let message): message
        case .stopped: "Starting…"
        case .running: adapter.hasSeenMedia ? "Working" : "Running, no media seen yet"
        }
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private static func openResource(_ name: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: "txt") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Says why some settings are off while low-resource mode is on.
private struct LowResourceNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "leaf")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shows a shortcut; click it to record a new one.
private struct ShortcutField: View {
    let action: HotkeyAction
    let hotkey: Hotkey?
    let isUnavailable: Bool
    let recorder: ShortcutRecorder

    var body: some View {
        let isRecording = recorder.recording == action
        HStack(spacing: 6) {
            if isUnavailable && !isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Another app already uses this shortcut, so macOS won't give it to MusicNotch.")
            }
            Button {
                if isRecording { recorder.stop() } else { recorder.start(action) }
            } label: {
                Text(isRecording ? "Press keys…" : hotkey?.display ?? "Record Shortcut")
                    .frame(minWidth: 110)
            }
            if hotkey != nil && !isRecording {
                Button {
                    recorder.clear(action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
    }
}
