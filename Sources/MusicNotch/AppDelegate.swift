import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private let model = NowPlaying()
    private let adapter = AdapterProcess()
    private let scripts = AppleScriptRunner()
    private lazy var appVolume = AppVolume(scripts: scripts)
    private lazy var playbackModes = AppPlaybackModes(scripts: scripts)
    private let hotkeys = HotkeyCenter()
    private var notch: NotchController?
    private var statusItem: NSStatusItem?
    private var terminationSignal: DispatchSourceSignal?
    private lazy var settings = SettingsWindowController(prefs: prefs, adapter: adapter, hotkeys: hotkeys)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened straight from Downloads, macOS runs a read-only temporary copy of the app,
        // where the media adapter can't be cleared to run.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            let alert = NSAlert()
            alert.messageText = "Move MusicNotch to Applications"
            alert.informativeText = "macOS runs apps opened straight from Downloads from a temporary copy, where MusicNotch can't read what's playing. Drag MusicNotch into your Applications folder, then open it from there."
            alert.addButton(withTitle: "Quit")
            NSApp.activate()
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let actions = NotchActions(
            playPause: { [weak self] in self?.togglePlayPause() },
            next: { [weak self] in self?.perform(.nextTrack) },
            previous: { [weak self] in self?.perform(.previousTrack) },
            openSourceApp: { [weak self] in self?.openSourceApp() },
            selectSource: { [weak self] sessionID in self?.model.pin(sessionID) },
            seek: { [weak self] position in self?.seek(to: position) },
            readVolume: { [weak self] bundleID, completion in
                guard let self else { return completion(nil) }
                appVolume.read(bundleID: bundleID, completion: completion)
            },
            setVolume: { [weak self] bundleID, level in
                self?.model.noteVolumeChange(bundleID: bundleID)
                self?.appVolume.set(level, bundleID: bundleID)
            },
            readModes: { [weak self] bundleID, completion in
                guard let self else { return completion(nil) }
                if DemoShot.current != nil { return completion(DemoShot.modes) }
                playbackModes.read(bundleID: bundleID, completion: completion)
            },
            toggleShuffle: { [weak self] bundleID, completion in
                guard let self else { return completion(nil) }
                playbackModes.toggleShuffle(bundleID: bundleID, completion: completion)
            },
            cycleRepeat: { [weak self] bundleID, completion in
                guard let self else { return completion(nil) }
                playbackModes.cycleRepeat(bundleID: bundleID, completion: completion)
            },
            contextMenu: { [weak self] in self?.makeMenu() ?? NSMenu() }
        )
        let notch = NotchController(model: model, prefs: prefs, actions: actions)
        self.notch = notch

        model.onPresenceChange = { [weak notch] visible in notch?.setVisible(visible) }
        model.onTrackChange = { [weak notch] in notch?.showTrackPeek() }
        adapter.onUpdate = { [weak model, weak notch] update in
            model?.receive(update)
            // "Hide in full screen" can depend on which app is playing.
            notch?.updateVisibility()
        }
        adapter.onTargetingUnavailable = { [weak model] in model?.canTargetApps = false }
        prefs.onAdapterOptionsChange = { [weak self] in
            guard let self else { return }
            adapter.start(options: prefs.adapterOptions)
        }
        prefs.onDisplayOptionsChange = { [weak notch] in notch?.rebuildPanels() }
        prefs.onMenuBarIconChange = { [weak self] in self?.updateStatusItem() }
        prefs.onSwipeOptionChange = { [weak notch] in notch?.updateSwipeMonitoring() }
        prefs.onFullScreenOptionChange = { [weak notch] in notch?.updateVisibility() }
        prefs.onHotkeysChange = { [weak self] in
            guard let self else { return }
            hotkeys.register(prefs.hotkeys)
        }
        hotkeys.onAction = { [weak self] action in self?.handle(action) }
        hotkeys.register(prefs.hotkeys)
        // Permission may have been granted in System Settings meanwhile; try again on return.
        settings.onBecameKey = { [weak notch] in notch?.updateSwipeMonitoring() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak notch] _ in
            MainActor.assumeIsolated { notch?.rebuildPanels() }
        }

        // `kill` and similar send SIGTERM, which would skip applicationWillTerminate
        // and leave the adapter running. Quit normally instead.
        signal(SIGTERM, SIG_IGN)
        let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        terminationSignal.resume()
        self.terminationSignal = terminationSignal

        updateStatusItem()
        if let shot = DemoShot.current {
            showDemo(shot)
        } else {
            adapter.start(options: prefs.adapterOptions)
        }
    }

    /// For the README screenshots: made-up tracks in place of the adapter's, and the notch
    /// opened in the shot's state once it's on screen.
    private func showDemo(_ shot: DemoShot) {
        model.receive(shot.update)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.notch?.showDemo(shot)
            if shot == .settings { self?.settings.show() }
        }
    }

    /// Opening the app again (Finder, Spotlight) shows Settings, which matters
    /// when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        adapter.stop()
    }

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .toggleNotch: notch?.toggleFromKeyboard()
        case .playPause: togglePlayPause()
        case .nextTrack: perform(.nextTrack)
        case .previousTrack: perform(.previousTrack)
        }
    }

    private func togglePlayPause() {
        guard model.canControlDisplayed else { return }
        model.togglePlayPauseOptimistically()
        perform(.togglePlayPause)
    }

    private func seek(to position: TimeInterval) {
        guard model.canControlDisplayed, model.snapshot?.canSeek == true else { return }
        model.seekOptimistically(to: position)
        perform(.seek(position))
    }

    /// Media commands go to macOS's "now playing" app, which stays the same even after it
    /// pauses. If the notch shows a different app, the command is sent to that app instead.
    private func perform(_ command: AdapterProcess.Command) {
        guard model.snapshot == nil || model.canControlDisplayed else { return }
        guard let snapshot = model.snapshot, !model.isDisplayedElected else {
            adapter.send(command)
            return
        }
        adapter.send(command, to: snapshot)
    }


    private func openSourceApp() {
        guard let bundleID = model.snapshot?.sourceAppBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    private func updateStatusItem() {
        if prefs.showMenuBarIcon, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "MusicNotch")
            item.menu = makeMenu()
            statusItem = item
        } else if !prefs.showMenuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit MusicNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        return menu
    }

    @objc private func showSettings() {
        settings.show()
    }
}
