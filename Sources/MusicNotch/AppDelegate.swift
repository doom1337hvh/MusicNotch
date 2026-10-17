import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Preferences()
    private let model = NowPlaying()
    private let adapter = AdapterProcess()
    private let scripts = AppleScriptRunner()
    private lazy var appVolume = AppVolume(scripts: scripts)
    private lazy var playbackModes = AppPlaybackModes(scripts: scripts)
    private lazy var mediaSearch = MediaSearch(scripts: scripts)
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
        // In a demo, nothing reaches the real players or apps, even if the notch is clicked.
        let demo = DemoScene.current != nil
        let actions = NotchActions(
            playPause: { [weak self] in if !demo { self?.togglePlayPause() } },
            next: { [weak self] in if !demo { self?.perform(.nextTrack) } },
            previous: { [weak self] in if !demo { self?.perform(.previousTrack) } },
            openSourceApp: { [weak self] in if !demo { self?.openSourceApp() } },
            selectSource: { [weak self] sessionID in self?.model.pin(sessionID) },
            seek: { [weak self] position in if !demo { self?.seek(to: position) } },
            readVolume: { [weak self] bundleID, completion in
                guard let self, !demo else { return completion(demo ? 0.7 : nil) }
                appVolume.read(bundleID: bundleID, completion: completion)
            },
            setVolume: { [weak self] bundleID, level in
                guard !demo else { return }
                self?.model.noteVolumeChange(bundleID: bundleID)
                self?.appVolume.set(level, bundleID: bundleID)
            },
            readModes: { [weak self] bundleID, completion in
                guard let self, !demo else { return completion(demo ? DemoScene.modes : nil) }
                playbackModes.read(bundleID: bundleID, completion: completion)
            },
            toggleShuffle: { [weak self] bundleID, completion in
                guard let self, !demo else { return completion(nil) }
                playbackModes.toggleShuffle(bundleID: bundleID, completion: completion)
            },
            cycleRepeat: { [weak self] bundleID, completion in
                guard let self, !demo else { return completion(nil) }
                playbackModes.cycleRepeat(bundleID: bundleID, completion: completion)
            },
            searchLibrary: { [weak self] query, completion in
                guard let self, !demo else { return completion(demo ? DemoScene.searchResults : nil) }
                mediaSearch.searchLibrary(query, completion: completion)
            },
            playSearchResult: { [weak self] result in if !demo { self?.mediaSearch.play(result) } },
            handOffSearch: { [weak self] query, target in if !demo { self?.mediaSearch.handOff(query, to: target) } },
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
        if let scene = DemoScene.current {
            runDemo(scene)
        } else {
            adapter.start(options: prefs.adapterOptions)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.warnIfSwipePermissionMissing()
            }
        }
    }

    /// "Hide while swiping" is on, but macOS doesn't let MusicNotch see the swipe gesture.
    private var swipePermissionMissing: Bool {
        prefs.hideDuringSwipes && !SwipeMonitor.hasPermission
    }

    /// macOS can drop the Input Monitoring permission, after an update for example, and
    /// "Hide while swiping" then silently does nothing. So say so at launch.
    private func warnIfSwipePermissionMissing() {
        guard swipePermissionMissing else { return }
        showSwipePermissionAlert()
    }

    @objc private func showSwipePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "“Hide while swiping” needs Input Monitoring"
        alert.informativeText = """
            macOS isn't letting MusicNotch see the swipe between desktops, so the notch can't \
            hide while you swipe. This can happen after an update.

            In System Settings → Privacy & Security → Input Monitoring, remove MusicNotch if \
            it's listed, then add it again with + and turn it on. Open System Settings also \
            shows MusicNotch in Finder, so you can drag it into the list.

            MusicNotch only listens for the swipe gesture: no keystrokes, no clicks.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Turn Off Hide While Swiping")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: SwipeMonitor.openPermissionSettings()
        case .alertSecondButtonReturn: prefs.hideDuringSwipes = false
        default: break
        }
    }

    /// For the README screenshots: made-up tracks in place of the adapter's, and the notch
    /// opened in the shot's state once it's on screen.
    // MARK: Demo scenes

    private var demoTrack = 0
    private var demoPlaying = true
    /// The track's position when it last changed, and when that was.
    private var demoElapsed: TimeInterval = 0
    private var demoSince = Date()

    /// For the README's clips (`DemoScene`): made-up tracks in place of the adapter's, then
    /// the scene's steps. The start time (`CACurrentMediaTime`) goes to the file named by
    /// `-demoClock`, so the recorder can line up its drawn pointer.
    private func runDemo(_ scene: DemoScene) {
        demoTrack = scene.firstTrack
        demoElapsed = DemoScene.tracks[demoTrack].elapsed
        showDemoTrack(scene)
        if scene == .settings { settings.show() }
        Task { [weak self] in
            // Gives the recorder time to start capturing first.
            try? await Task.sleep(for: .seconds(2.6))
            let start = CACurrentMediaTime()
            if let clock = UserDefaults.standard.string(forKey: "demoClock") {
                try? String(start).write(toFile: clock, atomically: true, encoding: .utf8)
            }
            for (time, step) in scene.steps {
                let wait = start + time - CACurrentMediaTime()
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                self?.runDemoStep(step, in: scene)
            }
        }
    }

    private func runDemoStep(_ step: DemoStep, in scene: DemoScene) {
        switch step {
        case .playing(let playing):
            demoElapsed = demoPosition
            demoPlaying = playing
            showDemoTrack(scene)
        case .track(let track):
            demoTrack = track
            demoElapsed = 0
            demoPlaying = true
            showDemoTrack(scene)
        case .seek(let fraction):
            demoElapsed = fraction * DemoScene.tracks[demoTrack].duration
            demoSince = Date()
            model.seekOptimistically(to: demoElapsed)
        case .select(let sessionID):
            model.pin(sessionID)
        case .settingsTab(let index):
            // In front, so the window looks active.
            settings.show()
            settings.selectTab(index)
        default:
            break
        }
        notch?.runDemoStep(step)
    }

    private var demoPosition: TimeInterval {
        demoPlaying ? demoElapsed + Date().timeIntervalSince(demoSince) : demoElapsed
    }

    private func showDemoTrack(_ scene: DemoScene) {
        demoSince = Date()
        model.receive(scene.update(track: demoTrack, playing: demoPlaying, elapsed: demoElapsed))
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
            // Rebuilt each time it opens, so the permission warning is up to date.
            item.menu?.delegate = self
            statusItem = item
        } else if !prefs.showMenuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        fill(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
    }

    private func fill(_ menu: NSMenu) {
        if swipePermissionMissing {
            let warning = NSMenuItem(title: "Allow Input Monitoring for “Hide while swiping”…",
                                     action: #selector(showSwipePermissionAlert), keyEquivalent: "")
            warning.target = self
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(warning)
            menu.addItem(.separator())
        }
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit MusicNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
    }

    @objc private func showSettings() {
        settings.show()
    }
}
