import AppKit
import Observation
import OSLog
import SwiftUI

@MainActor
struct NotchActions {
    var playPause: @MainActor () -> Void
    var next: @MainActor () -> Void
    var previous: @MainActor () -> Void
    var openSourceApp: @MainActor () -> Void
    var selectSource: @MainActor (String) -> Void
    /// Jumps the shown app to a position, in seconds.
    var seek: @MainActor (TimeInterval) -> Void
    /// Reads an app's own volume (0...1), or nil if it can't; see `AppVolume`.
    var readVolume: @MainActor (String, @escaping @MainActor @Sendable (Double?) -> Void) -> Void
    var setVolume: @MainActor (String, Double) -> Void
    /// Shuffle and repeat for apps that can be scripted; see `AppPlaybackModes`.
    var readModes: @MainActor (String, @escaping @MainActor @Sendable (PlaybackModes?) -> Void) -> Void
    /// These report the modes the app was set to, or nil if it couldn't be controlled.
    var toggleShuffle: @MainActor (String, @escaping @MainActor @Sendable (PlaybackModes?) -> Void) -> Void
    var setRepeat: @MainActor (String, RepeatMode, @escaping @MainActor @Sendable (PlaybackModes?) -> Void) -> Void
    /// Search (see `MediaSearch`): Music's library, a result to play, or a hand-off.
    var searchLibrary: @MainActor (String, @escaping @MainActor @Sendable ([SearchResult]?) -> Void) -> Void
    var playSearchResult: @MainActor (SearchResult) -> Void
    var handOffSearch: @MainActor (String, SearchTarget) -> Void
    /// For apps playing sound without Now Playing; see `Microphone` and `SoundApps`.
    var toggleMicrophone: @MainActor () -> Void
    var toggleDeafen: @MainActor (String) -> Void
    var contextMenu: @MainActor () -> NSMenu
}

@Observable @MainActor
final class NotchState {
    let geometry: NotchGeometry
    var isExpanded = false
    /// Widened on hover to show the skip buttons (Minimal style).
    var isPeeking = false
    /// The panel open while `isExpanded`: Compact or Full.
    var expandedStyle: NotchStyle = .full
    /// Open only briefly to show a new track ("Show new tracks").
    var isTrackPeek = false
    /// The open panel: as wide as the strip of app icons at the top, and as tall as the body.
    var expandedSize: CGSize
    /// The body below the strip; narrower than `expandedSize` when the strip reaches further
    /// out to fit many app icons.
    var expandedBodyWidth: CGFloat
    /// Horizontal offset of the collapsed artwork and equalizer, for the Slide animation.
    var contentOffset: CGFloat = 0
    /// The whole notch's scale, and the contents' blur, for the other desktop-switch animations.
    var appearScale: CGFloat = 1
    var appearContentBlur: CGFloat = 0
    /// How far the closed notch has grown out of the camera housing, for Expand (see `AppearStart`).
    var appearGrowth: CGFloat = 1
    /// Counts the desktop-switch animations' starting points: changed along with them, so the
    /// view can report when it has applied one (`onAppearStartApplied`).
    var appearStart = 0
    /// The volume slider, shown in place of the playback buttons for apps with their own volume.
    var showsVolume = false
    var volumeBundleID: String?
    var volumeLevel: Double?
    var volumeUnavailable = false
    /// The shown app's shuffle and repeat (Spotify and Music), once read.
    var modes: PlaybackModes?
    var modesBundleID: String?
    /// True if the app couldn't be controlled, usually because Automation access was denied.
    var modesUnavailable = false
    /// The search field, while it's open in place of the controls.
    var search: SearchState?
    /// Where the progress bar is being dragged to, 0...1, while it's dragged.
    var scrubFraction: Double?
    @ObservationIgnored var onHover: ((Bool) -> Void)?
    @ObservationIgnored var onScrubEnded: (() -> Void)?
    @ObservationIgnored var onSearch: ((SearchEvent) -> Void)?
    @ObservationIgnored var onTap: (() -> Void)?
    @ObservationIgnored var onAppearStartApplied: ((Int) -> Void)?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        let size = geometry.expandedSize(showsProgress: true)
        expandedSize = size
        expandedBodyWidth = size.width
    }
}

/// Keeps one panel on every notched screen (and, if enabled, every other screen),
/// shown only while something is playing.
@MainActor
final class NotchController {
    private let model: NowPlaying
    private let prefs: Preferences
    private let actions: NotchActions
    private var panels: [NotchPanelController] = []
    private var isVisible = false
    private var isScreenLocked = false
    private let spaces = SpaceObserver()
    private let swipes = SwipeMonitor()
    private var swipeEndTask: Task<Void, Never>?
    /// From the start of a swipe ("Hide while swiping") until the panels come back after it.
    private var isSwiping = false
    /// Fingers still on the trackpad: between a swipe's start and its release.
    private var isSwipeHeld = false
    /// A rebuild waiting for a display change to settle (see `screensChanged`).
    private var rebuildTask: Task<Void, Never>?
    /// While swipes are being watched, panels live in a Space above every desktop, so they
    /// never ride along with a sliding desktop. Created the first time it's needed.
    private var pinnedSpace: NotchSpace?
    private var pinsPanels = false

    init(model: NowPlaying, prefs: Preferences, actions: NotchActions) {
        self.model = model
        self.prefs = prefs
        self.actions = actions
        spaces.onSwitch = { [weak self] displayUUID, direction in
            // A demo clip (`DemoScene`) holds still whatever the desktop does.
            guard let self, DemoScene.current == nil else { return }
            Self.logger.debug("""
                switch reported: display=\(displayUUID ?? "all", privacy: .public) \
                direction=\(String(describing: direction), privacy: .public) swiping=\(self.isSwiping, privacy: .public)
                """)
            // Show or hide for full screen first, so a panel that's about to hide doesn't
            // play its appear animation, and one that comes back (say, on leaving a
            // full-screen app) plays it rather than popping in.
            let shownBefore = panels.map(\.isShown)
            updateVisibility(afterSwitch: true, direction: direction)
            // The swipe has landed, even if its release went unreported. Not while one is still
            // held, though: swiping again quickly, the last switch's report can arrive just
            // after the next swipe begins, and would bring the notch back mid-swipe.
            if isSwiping && !isSwipeHeld { finishSwipe(direction: direction) }
            for (panel, wasShown) in zip(panels, shownBefore)
            where wasShown && (displayUUID == nil || panel.displayUUID == displayUUID) {
                panel.desktopSwitched(direction: direction)
            }
        }
        // "When the playing app is" full screen depends on which app is in front.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Switching desktops activates an app there before macOS reports the switch,
                // so a panel coming back here is often part of one.
                self.updateVisibility(afterSwitch: true)
                // Coming back from allowing Input Monitoring in System Settings: start listening.
                if self.prefs.hideDuringSwipes && !self.pinsPanels { self.updateSwipeMonitoring() }
            }
        }
        swipes.onSwipeBegan = { [weak self] in
            if DemoScene.current == nil { self?.swipeBegan() }
        }
        swipes.onSwipeEnded = { [weak self] direction in
            if DemoScene.current == nil { self?.swipeEnded(direction: direction) }
        }
        // Pinned panels sit above the lock screen too, so step aside while locked.
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isScreenLocked = locked
                    self?.updateVisibility()
                }
            }
        }
        updateSwipeMonitoring()
        rebuildPanels()
    }

    /// Starts or stops listening for swipes to match "Hide while swiping" and the permission,
    /// and pins the panels above the desktops while listening.
    func updateSwipeMonitoring() {
        let listening = prefs.hideDuringSwipes && swipes.start()
        if !prefs.hideDuringSwipes { swipes.stop() }
        guard listening != pinsPanels else { return }
        pinsPanels = listening
        if !panels.isEmpty { rebuildPanels() }
    }

    private func swipeBegan() {
        swipeEndTask?.cancel()
        isSwiping = true
        isSwipeHeld = true
        panels.forEach { $0.hideForSwipe() }
        // Should the swipe's end go unreported, don't leave the panels hidden.
        swipeEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.finishSwipe(direction: nil)
        }
    }

    /// Brings the panels back as the desktop settles after the swipe is released. macOS only
    /// reports the switch once it has settled, which is noticeably later.
    ///
    /// The panels instead wait for that report:
    /// - With "Hide in full screen" on and the swipe heading to a full-screen app's desktop, in
    ///   case they should stay hidden there; otherwise they'd flash up and vanish.
    /// - With an animation that moves the notch and the swipe heading to an ordinary desktop.
    ///   Until the switch is over, macOS often keeps showing the notch's old frames there, so
    ///   the animation would play unseen and the notch would show up already at rest.
    ///
    /// A cancelled swipe never gets a report, so they give up after 1.2 s.
    private func swipeEnded(direction: SpaceObserver.Direction?) {
        swipeEndTask?.cancel()
        isSwipeHeld = false
        let waitForDestination = direction.map { direction in
            prefs.hideInFullScreen != .never && spaces.swipeLandsOnFullScreen(direction)
                || prefs.effectiveSpaceSwitchAnimation.moves && spaces.swipeLandsOnDesktop(direction)
        } == true
        swipeEndTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(waitForDestination ? 1200 : 400))
            guard !Task.isCancelled else { return }
            self?.finishSwipe(direction: direction)
        }
    }

    /// Ends the swipe and brings the panels back.
    private func finishSwipe(direction: SpaceObserver.Direction?) {
        swipeEndTask?.cancel()
        isSwiping = false
        isSwipeHeld = false
        panels.forEach { $0.appearAfterSwipe(direction: direction) }
    }

    /// macOS says the displays changed. Switching to or from a full-screen app can say so too
    /// (the menu bar and Dock change), and mid-switch a screen can briefly read as having no
    /// notch; a notch rebuilt then would come up the wrong size, inside the camera housing.
    /// So this waits for things to settle and rebuilds only if a notch actually changed.
    func screensChanged() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            // A screen with a notch that now reads as having none is most likely mid-switch;
            // believe it only if it still does a little later.
            let hadNotch = Set(panels.filter(\.geometry.hasNotch).compactMap(\.displayUUID))
            if NSScreen.screens.contains(where: { screen in
                screen.displayUUID.map(hadNotch.contains) == true && !NotchGeometry(screen: screen).hasNotch
            }) {
                Self.logger.debug("a notch went missing; checking again")
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            let current = panels.map { "\($0.displayUUID ?? "?") \($0.geometry)" }
            let fresh = shownScreens.map { "\($0.screen.displayUUID ?? "?") \($0.geometry)" }
            guard current != fresh else { return Self.logger.debug("screens changed, notches didn't") }
            Self.logger.debug("screens changed: rebuilding")
            rebuildPanels()
        }
    }

    /// The screens that get a notch, with its geometry.
    private var shownScreens: [(screen: NSScreen, geometry: NotchGeometry)] {
        NSScreen.screens.compactMap { screen in
            let geometry = NotchGeometry(screen: screen)
            return geometry.hasNotch || prefs.showOnExternalDisplays ? (screen, geometry) : nil
        }
    }

    func rebuildPanels() {
        rebuildTask?.cancel()
        panels.forEach { $0.close() }
        if pinsPanels && pinnedSpace == nil { pinnedSpace = NotchSpace() }
        let space = pinsPanels ? pinnedSpace : nil
        panels = shownScreens.map { screen, geometry in
            NotchPanelController(geometry: geometry, displayUUID: screen.displayUUID, pinnedTo: space,
                                 model: model, prefs: prefs, actions: actions)
        }
        // Mid-swipe, the new panels wait to appear with the swipe's animation.
        updateVisibility(afterSwitch: isSwiping)
    }

    /// "Hide" on the notch: a closed notch takes its new size now, an open one as it closes.
    func notchHiddenChanged() {
        panels.forEach { $0.fitClosedSize() }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        updateVisibility()
    }

    func showTrackPeek() {
        panels.forEach { $0.showTrackPeek() }
    }

    /// The shown app or track changed: an open panel fits the new one's buttons, and a
    /// closed one briefly shows it ("Show new tracks").
    func trackChanged() {
        panels.forEach { $0.trackChanged() }
    }

    /// Acts out a step of a README clip (see `DemoScene.steps`).
    func runDemoStep(_ step: DemoStep) {
        panels.forEach { $0.runDemoStep(step) }
    }

    /// The keyboard shortcut: opens or closes the notch on the screen with the pointer, or
    /// else the built-in display.
    func toggleFromKeyboard() {
        let pointer = NSEvent.mouseLocation
        let panel = panels.first { $0.isShownOnScreen && $0.screenFrame.contains(pointer) }
            ?? panels.first { $0.isShownOnScreen && $0.hasNotch }
            ?? panels.first { $0.isShownOnScreen }
        panel?.toggleFromKeyboard()
    }

    /// Re-checks which panels should show, e.g. after the media or the "Hide in full screen"
    /// setting changed.
    func updateVisibility() {
        updateVisibility(afterSwitch: false)
    }

    /// `afterSwitch`: the change comes with a desktop switch, so a panel that comes back plays
    /// "Appear on the new desktop", or during a swipe, waits to appear with the others.
    private func updateVisibility(afterSwitch: Bool, direction: SpaceObserver.Direction? = nil) {
        let appearance: NotchPanelController.Appearance = !afterSwitch ? .immediately
            : isSwiping ? .afterSwipe : .animated(direction)
        for panel in panels {
            panel.setVisible(isVisible && !isScreenLocked && !hidesForFullScreen(panel), appearance: appearance)
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicNotch", category: "switch")

    private func hidesForFullScreen(_ panel: NotchPanelController) -> Bool {
        switch prefs.hideInFullScreen {
        case .never:
            return false
        case .anyApp:
            return spaces.isFullScreen(displayUUID: panel.displayUUID)
        case .playingApp:
            return spaces.isFullScreen(displayUUID: panel.displayUUID) && frontAppIsPlayingMedia
        }
    }

    /// Whether the app in front is one that's playing media. A Chrome web app (YouTube,
    /// SoundCloud) reports media as "com.google.Chrome.app.<id>", so match on that prefix too.
    private var frontAppIsPlayingMedia: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return model.sessions.contains { session in
            let ids = [session.snapshot.bundleID, session.snapshot.parentBundleID].compactMap { $0 }
            return session.snapshot.isPlaying
                && ids.contains { $0 == front || $0.hasPrefix(front + ".app.") || front.hasPrefix($0 + ".app.") }
        }
    }
}

@MainActor
private final class NotchPanelController {
    let displayUUID: String?
    var geometry: NotchGeometry { state.geometry }
    private let panel: NotchPanel
    /// The camera-area target, with "Only open from the camera" on a notched screen.
    private let hotspot: NotchHotspot?
    /// Set when the panel is pinned above every desktop ("Hide while swiping").
    private let space: NotchSpace?
    private let state: NotchState
    private let model: NowPlaying
    private let prefs: Preferences
    private let actions: NotchActions
    private var hoverTask: Task<Void, Never>?
    private var trackPeekTask: Task<Void, Never>?
    /// A Music library search waiting for typing to pause.
    private var searchTask: Task<Void, Never>?
    private var resignKeyObserver: NSObjectProtocol?
    /// Closes a notch opened from the keyboard if the pointer never comes over it.
    private var keyboardCloseTask: Task<Void, Never>?
    private(set) var isShown = false
    private var isHiddenForSwipe = false
    /// The animation to start once the panel is actually on screen (see `animateIn`).
    private var pendingSlide: (() -> Void)?
    /// Whether the view has applied the pending animation's starting point.
    private var isAppearStartApplied = false
    /// While "Appear on the new desktop" plays; each appear gets a new generation, so an
    /// earlier one finishing doesn't count.
    private var isAppearing = false
    private var appearGeneration = 0
    /// A new track arrived mid-switch; its peek shows once the notch has settled.
    private var peekWaiting = false
    private var occlusionObserver: NSObjectProtocol?
    private var slideStartTask: Task<Void, Never>?
    private var slideFallbackTask: Task<Void, Never>?

    /// "Hidden" opacity. Not quite 0, so macOS keeps treating the window as on screen.
    private static let hiddenAlpha: CGFloat = 0.01
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicNotch", category: "switch")

    init(geometry: NotchGeometry, displayUUID: String?, pinnedTo space: NotchSpace?, model: NowPlaying,
         prefs: Preferences, actions: NotchActions) {
        self.displayUUID = displayUUID
        self.space = space
        self.model = model
        self.prefs = prefs
        self.actions = actions
        state = NotchState(geometry: geometry)
        panel = NotchPanel(frame: geometry.frame(for: geometry.closedSize(showsContent: prefs.effectiveShowBesideNotch)),
                           pinned: space != nil)
        // A few points inside the camera housing on each side and at the bottom.
        hotspot = prefs.openFromCameraOnly && geometry.hasNotch
            ? NotchHotspot(frame: geometry.frame(for: geometry.insideHousingSize),
                           pinned: space != nil)
            : nil

        let host = NotchHostingView(rootView: NotchRootView(model: model, prefs: prefs, state: state, actions: actions))
        // The panel's frame is managed here; don't let SwiftUI resize it.
        host.sizingOptions = []
        host.contextMenu = actions.contextMenu
        panel.contentView = host
        state.onHover = { [weak self] inside in self?.panelHoverChanged(inside) }
        state.onTap = { [weak self] in self?.tapped() }
        state.onScrubEnded = { [weak self] in self?.scrubEnded() }
        state.onSearch = { [weak self] event in self?.handleSearch(event) }
        state.onAppearStartApplied = { [weak self] start in self?.appearStartApplied(start) }
        // Clicking into another app while searching closes the search.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelResignedKey() }
        }
        hotspot?.onHover = { [weak self] inside in self?.cameraHoverChanged(inside) }
        hotspot?.onClick = { [weak self] in self?.tapped() }
        hotspot?.contextMenu = actions.contextMenu
        updateMouseHandling()
    }

    var isShownOnScreen: Bool { isShown && !isHiddenForSwipe }
    var screenFrame: CGRect { state.geometry.screenFrame }
    var hasNotch: Bool { state.geometry.hasNotch }

    /// With the camera-area target, the closed notch lets the pointer through to the menu
    /// bar; once open, the panel handles the pointer itself.
    private func updateMouseHandling() {
        panel.ignoresMouseEvents = hotspot != nil && !isOpen
    }

    /// The pointer over the panel. Its hover tracking keeps reporting even while the panel
    /// ignores the pointer, so with the camera-area target only an open panel listens to it.
    private func panelHoverChanged(_ inside: Bool) {
        if hotspot != nil && !isOpen { return }
        hoverChanged(inside)
    }

    /// The pointer entering or leaving the camera area while the notch is closed. Once it's
    /// open, the panel's own hover tracking decides when it closes.
    private func cameraHoverChanged(_ inside: Bool) {
        guard !isOpen, !isHiddenForSwipe else { return }
        hoverChanged(inside)
    }

    /// How a hidden panel comes back.
    enum Appearance {
        case immediately
        /// With "Appear on the new desktop", after a desktop switch.
        case animated(SpaceObserver.Direction?)
        /// Out of sight until the swipe under way ends, then with the other panels.
        case afterSwipe
    }

    func setVisible(_ visible: Bool, appearance: Appearance = .immediately) {
        guard visible != isShown else { return }
        isShown = visible
        if visible {
            Self.logger.debug("showing: \(String(describing: appearance), privacy: .public)")
            // The target sits under the panel, so the panel gets the pointer whenever it takes it.
            if let hotspot {
                hotspot.orderFrontRegardless()
                space?.add(hotspot)
            }
            if case .immediately = appearance {
                panel.alphaValue = 1
            } else {
                panel.alphaValue = Self.hiddenAlpha
            }
            if case .afterSwipe = appearance { isHiddenForSwipe = true }
            panel.orderFrontRegardless()
            space?.add(panel)
            if case .animated(let direction) = appearance { appear(direction: direction) }
        } else {
            isHiddenForSwipe = false
            isAppearing = false
            peekWaiting = false
            hotspot?.orderOut(nil)
            hoverTask?.cancel()
            trackPeekTask?.cancel()
            state.isExpanded = false
            state.isPeeking = false
            state.isTrackPeek = false
            state.showsVolume = false
            state.search = nil
            relinquishKey()
            setWindowSize(closedSize)
            panel.orderOut(nil)
            updateMouseHandling()
        }
    }

    func close() {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        searchTask?.cancel()
        hoverTask?.cancel()
        trackPeekTask?.cancel()
        if let hotspot {
            space?.remove(hotspot)
            hotspot.orderOut(nil)
            hotspot.close()
        }
        slideStartTask?.cancel()
        slideFallbackTask?.cancel()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        space?.remove(panel)
        panel.orderOut(nil)
        panel.close()
    }

    /// Called when macOS reports a desktop switch, once the new desktop has settled.
    func desktopSwitched(direction: SpaceObserver.Direction?) {
        Self.logger.debug("desktop switched: \(String(describing: direction), privacy: .public)")
        // Pinned panels never move with the desktops; after a swipe they come back via
        // `appearAfterSwipe`, which doesn't wait for this late notification.
        guard isShown, space == nil else { return }
        // This panel lives on one desktop and left with the old one; bring it to the new one.
        collapseImmediately()
        panel.alphaValue = Self.hiddenAlpha
        if let hotspot {
            hotspot.orderOut(nil)
            hotspot.orderFrontRegardless()
        }
        panel.orderOut(nil)
        panel.orderFrontRegardless()  // joins the now-active desktop (.moveToActiveSpace)
        appear(direction: direction)
    }

    /// Brings the panel back after a swipe hid it ("Hide while swiping"): with the
    /// direction the desktop moved, or nil if the swipe sprang back.
    func appearAfterSwipe(direction: SpaceObserver.Direction?) {
        guard isHiddenForSwipe else { return }
        Self.logger.debug("appearing after swipe: \(String(describing: direction), privacy: .public)")
        isHiddenForSwipe = false
        appear(direction: direction)
    }

    /// Plays the chosen "Appear on the new desktop" animation from hidden.
    private func appear(direction: SpaceObserver.Direction?) {
        let animation = prefs.effectiveSpaceSwitchAnimation
        guard animation != .none else {
            panel.alphaValue = 1
            return appearSettled(appearGeneration)
        }
        appearGeneration += 1
        isAppearing = true
        let generation = appearGeneration
        // Slide without a known direction falls back to the plain fade.
        let motion = animation.motion(direction: direction, geometry: state.geometry)
        Self.logger.debug("""
            appearing: \(String(describing: animation), privacy: .public) \
            direction=\(String(describing: direction), privacy: .public) motion=\(motion != nil, privacy: .public) \
            onScreen=\(self.panel.occlusionState.contains(.visible), privacy: .public)
            """)
        if let motion {
            // The fade starts with the motion, which may wait for the window to be on screen;
            // fading in first would show the notch at its starting point, waiting.
            animateIn(from: motion.start, curve: motion.curve, generation: generation)
        } else {
            fadeIn(duration: 0.3) { [weak self] in self?.appearSettled(generation) }
        }
    }

    /// The appear animation `generation` finished: a new track's peek that waited for it
    /// shows now.
    private func appearSettled(_ generation: Int) {
        guard generation == appearGeneration else { return }
        isAppearing = false
        guard peekWaiting else { return }
        peekWaiting = false
        showTrackPeek()
    }

    /// The whole notch fades in, so its black shape emerges with the artwork instead of
    /// popping in under it. The window server runs the fade; the app does no per-frame work.
    private func fadeIn(duration: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    /// Fades out as a swipe between desktops begins ("Hide while swiping"). An open notch
    /// fades out as it is and closes once it's out of sight, rather than visibly snapping shut.
    func hideForSwipe() {
        guard isShown, !isHiddenForSwipe else { return }
        isHiddenForSwipe = true
        hoverTask?.cancel()
        trackPeekTask?.cancel()
        cancelPendingSlide()
        let wasOpen = isOpen
        NSAnimationContext.runAnimationGroup { context in
            context.duration = wasOpen ? 0.18 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = Self.hiddenAlpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHiddenForSwipe else { return }
                self.collapseImmediately()
            }
        }
    }

    /// Moves the notch from `start` back to rest with `curve` (a slide, zoom, bounce, blur or
    /// expand).
    ///
    /// The animation only starts once the notch is at its starting point on screen; started
    /// any sooner, it would show up finished or half-way. That takes two things:
    /// - The view has applied the starting point. It usually has within a millisecond, but
    ///   during quick swipes between desktops it can take longer, and SwiftUI then merges the
    ///   two changes, so nothing moves. So the view reports when it has.
    /// - The window is on screen. macOS pauses SwiftUI animations in windows that are off
    ///   screen, and a window that has just moved desktops still counts as off screen for a
    ///   moment.
    ///
    /// The window keeps its size unless the animation springs past the notch's full size.
    /// Mid-switch, macOS can apply a new window size but keep showing the old contents until
    /// the switch ends, pinned to the window's bottom left: the notch would show up below and
    /// left of the housing, standing still.
    private func animateIn(from start: AppearStart, curve: Animation, generation: Int) {
        pendingSlide = { [weak self] in
            if start.fades {
                self?.fadeIn(duration: 0.18)
            } else {
                self?.panel.alphaValue = 1
            }
            withAnimation(curve) {
                self?.state.contentOffset = 0
                self?.state.appearScale = 1
                self?.state.appearContentBlur = 0
                self?.state.appearGrowth = 1
            } completion: {
                guard let self else { return }
                self.appearSettled(generation)
                guard !self.isOpen, self.panel.frame.size != self.closedSize else { return }
                self.setWindowSize(self.closedSize)
            }
        }
        isAppearStartApplied = false
        // Don't leave the notch hidden at its starting point if the wait never ends.
        slideStartTask?.cancel()
        slideFallbackTask?.cancel()
        slideFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.startPendingSlide(reason: "fallback timeout")
        }
        if occlusionObserver == nil {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.startPendingSlideIfReady(reason: "came on screen")
                }
            }
        }

        var noAnimation = Transaction()
        noAnimation.disablesAnimations = true
        withTransaction(noAnimation) {
            state.contentOffset = start.contentOffset
            state.appearScale = start.scale
            state.appearContentBlur = start.contentBlur
            state.appearGrowth = start.growth
            state.appearStart += 1
        }
        if start.overshoots {
            // Room around the closed notch, so a bounce isn't cut off by the window edges.
            let bar = closedSize
            setWindowSize(CGSize(width: bar.width + 2 * Self.overshootMargin, height: bar.height + Self.overshootMargin))
        } else {
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        startPendingSlideIfReady(reason: "already on screen")
    }

    /// The view has applied the starting point `start`.
    private func appearStartApplied(_ start: Int) {
        guard start == state.appearStart, pendingSlide != nil, !isAppearStartApplied else { return }
        isAppearStartApplied = true
        startPendingSlideIfReady(reason: "start applied")
    }

    /// Starts the pending animation if the notch is at its starting point on screen.
    private func startPendingSlideIfReady(reason: String) {
        guard pendingSlide != nil, isAppearStartApplied, panel.occlusionState.contains(.visible) else { return }
        startPendingSlideAfterAFrame(reason: reason)
    }

    /// Waits one display frame so the starting point is drawn before the animation begins.
    private func startPendingSlideAfterAFrame(reason: String) {
        slideStartTask?.cancel()
        slideStartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            self?.startPendingSlide(reason: reason)
        }
    }

    private func startPendingSlide(reason: String) {
        slideStartTask?.cancel()
        slideFallbackTask?.cancel()
        guard let slide = pendingSlide else { return }
        pendingSlide = nil
        Self.logger.debug("slide started: \(reason, privacy: .public)")
        slide()
    }

    /// Drops an animation still waiting to start: the notch is hiding again.
    private func cancelPendingSlide() {
        slideStartTask?.cancel()
        slideFallbackTask?.cancel()
        pendingSlide = nil
    }

    private var isOpen: Bool { state.isExpanded || state.isPeeking }

    func fitClosedSize() {
        guard !isOpen, !isAppearing, panel.frame.size != closedSize else { return }
        setWindowSize(closedSize)
    }

    /// The closed notch's size; see `NotchGeometry.closedSize`.
    private var closedSize: CGSize {
        state.geometry.closedSize(showsContent: prefs.effectiveShowBesideNotch)
    }

    private func collapseImmediately() {
        hoverTask?.cancel()
        trackPeekTask?.cancel()
        keyboardCloseTask?.cancel()
        guard isOpen else { return }
        state.isExpanded = false
        state.isPeeking = false
        state.isTrackPeek = false
        state.showsVolume = false
        state.search = nil
        relinquishKey()
        setWindowSize(closedSize)
        updateMouseHandling()
    }

    /// "Show new tracks": briefly opens a banner with the new track, then closes again.
    func trackChanged() {
        guard state.isExpanded, !state.isTrackPeek else { return showTrackPeek() }
        // While searching, the panel is sized for the search; it fits again when that closes.
        guard state.search == nil else { return }
        let (size, bodyWidth) = panelSize(style: state.expandedStyle)
        guard size != state.expandedSize || bodyWidth != state.expandedBodyWidth else { return }
        growWindow(toFit: size)
        withAnimation(.smooth(duration: 0.25)) {
            state.expandedSize = size
            state.expandedBodyWidth = bodyWidth
        }
    }

    func showTrackPeek(stayOpen: Bool = false) {
        guard isShown, prefs.effectiveShowTrackPeek || stayOpen, !isOpen else { return }
        // Mid-switch it would cut into "Appear on the new desktop"; wait for the notch to settle.
        if isHiddenForSwipe || isAppearing {
            peekWaiting = true
            return
        }
        let size = state.geometry.trackPeekSize
        state.expandedSize = size
        state.expandedBodyWidth = size.width
        state.isTrackPeek = true
        setWindowSize(CGSize(width: size.width + 2 * Self.overshootMargin, height: size.height + Self.overshootMargin))
        withAnimation(prefs.effectiveOpenAnimation.trackPeekOpening) { state.isExpanded = true }
        updateMouseHandling()
        trackPeekTask?.cancel()
        guard !stayOpen else { return }
        trackPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, self.state.isTrackPeek else { return }
            self.collapse(gently: true)
        }
    }

    /// Opens the notch in a README screenshot's state, without waiting for the pointer.
    func runDemoStep(_ step: DemoStep) {
        switch step {
        case .open(let style): if style == .minimal { peek() } else { expand(style: style) }
        case .collapse: collapse()
        case .startSearch: startSearch()
        case .search(let text, let results):
            state.search?.text = text
            state.search?.results = results
            resizeForSearch()
        case .closeSearch: endSearch(thenCollapse: true)
        case .scrub(let fraction): state.scrubFraction = fraction
        case .seek: state.scrubFraction = nil
        case .modes(let modes):
            state.modesBundleID = model.snapshot?.bundleID
            state.modes = modes
        // The app delegate changes what's playing, and Settings.
        case .playing, .track, .select, .settingsTab, .microphone, .deafen: break
        }
    }

    /// Opens the notch, or closes it if it's open. Opened this way it stays open while the
    /// pointer is over it, and otherwise closes after a few seconds.
    func toggleFromKeyboard() {
        guard isShownOnScreen else { return }
        if isOpen && !state.isTrackPeek {
            collapse()
            return
        }
        hoverTask?.cancel()
        trackPeekTask?.cancel()
        open()
        keyboardCloseTask?.cancel()
        keyboardCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.isOpen else { return }
            self.collapse()
        }
    }

    private func hoverChanged(_ inside: Bool) {
        // A demo clip (`DemoScene`) holds still wherever the pointer goes.
        guard DemoScene.current == nil else { return }
        hoverTask?.cancel()
        // The pointer reached a notch opened from the keyboard; from here, leaving closes it.
        if inside { keyboardCloseTask?.cancel() }
        if inside && state.isTrackPeek {
            // Keep the banner while the pointer is on it, and open the usual panel on hover.
            trackPeekTask?.cancel()
            if prefs.openTrigger == .hover && prefs.notchStyle != .minimal {
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    self?.expand()
                }
            }
            return
        }
        guard inside != isOpen else { return }
        // With "Open on: Click", hovering only keeps an open notch open.
        if inside && prefs.openTrigger == .click { return }
        // A short delay on enter ignores the cursor passing by on its way to the menu bar;
        // the delay on exit keeps the panel from closing when the cursor slips off an edge.
        let delay: Duration = inside ? .milliseconds(120) : .milliseconds(300)
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if inside {
                self.open()
            } else if self.state.scrubFraction == nil && self.state.search == nil {
                // Mid-drag on the progress bar, `scrubEnded` decides instead; while searching,
                // the notch stays open for typing.
                self.collapse()
            }
        }
    }

    /// A drag on the progress bar may end with the pointer outside the panel; close it
    /// then, as leaving it would have.
    private func scrubEnded() {
        let shape = state.geometry.frame(for: isOpen && state.isExpanded ? state.expandedSize : closedSize)
        guard isOpen, !shape.contains(NSEvent.mouseLocation) else { return }
        hoverChanged(false)
    }

    /// "Open on: Click": a click anywhere on the closed notch opens it.
    private func tapped() {
        guard prefs.openTrigger == .click, DemoScene.current == nil else { return }
        if state.isTrackPeek {
            // A click on the new-track banner opens the usual panel.
            trackPeekTask?.cancel()
            if prefs.notchStyle != .minimal { expand() }
            return
        }
        guard !isOpen else { return }
        hoverTask?.cancel()
        open()
    }

    /// Opens into the chosen style.
    private func open() {
        if prefs.notchStyle == .minimal { peek() } else { expand() }
    }

    /// Widens the notch sideways to show the skip buttons.
    private func peek() {
        let size = state.geometry.peekSize
        setWindowSize(CGSize(width: size.width + 2 * Self.overshootMargin, height: size.height + Self.overshootMargin))
        withAnimation(prefs.effectiveOpenAnimation.opening) { state.isPeeking = true }
        updateMouseHandling()
    }

    /// Opens the Compact or Full panel: `style`, or else the one chosen in Settings.
    /// The Compact or Full panel's size for what's playing, and its body's width: narrower
    /// when the strip of app icons at the top reaches further out.
    private func panelSize(style: NotchStyle) -> (size: CGSize, bodyWidth: CGFloat) {
        let showsProgress = prefs.effectiveProgressBar && model.snapshot?.duration != nil
        let showsModes = prefs.showShuffleRepeat
            && model.snapshot.map { AppPlaybackModes.supports(bundleID: $0.bundleID) } == true
        let showsSearch = prefs.showSearch
            && model.snapshot.flatMap { $0.isSoundOnly ? nil : SearchTarget.forApp(of: $0) } != nil
        let body = style == .compact
            ? state.geometry.compactSize(showsProgress: showsProgress, showsModes: showsModes, showsSearch: showsSearch)
            : state.geometry.expandedSize(showsProgress: showsProgress)
        let band = state.geometry.bandWidth(forBody: body.width, sourceCount: model.sessions.count)
        return (CGSize(width: band, height: body.height), body.width)
    }

    private func expand(style: NotchStyle? = nil) {
        let style = style ?? prefs.notchStyle
        state.expandedStyle = style
        (state.expandedSize, state.expandedBodyWidth) = panelSize(style: style)
        // Grow the transparent window first (with room for the spring's overshoot),
        // then animate the shape inside it.
        let margin = Self.overshootMargin
        setWindowSize(CGSize(width: state.expandedSize.width + 2 * margin,
                             height: state.expandedSize.height + margin))
        withAnimation(prefs.effectiveOpenAnimation.opening) {
            state.isExpanded = true
            state.isPeeking = false
            state.isTrackPeek = false
        }
        updateMouseHandling()
    }

    /// `gently`: the slower close of a new track's peek.
    private func collapse(gently: Bool = false) {
        keyboardCloseTask?.cancel()
        searchTask?.cancel()
        relinquishKey()
        let shrinkWindow = { [weak self] in
            guard let self, !self.isOpen else { return }
            self.setWindowSize(self.closedSize)
        }
        let animation = prefs.effectiveOpenAnimation
        if let closing = gently ? animation.trackPeekClosing : animation.closing {
            withAnimation(closing) {
                state.isExpanded = false
                state.isPeeking = false
                state.isTrackPeek = false
            } completion: {
                self.state.showsVolume = false
                self.state.search = nil
                shrinkWindow()
            }
        } else {
            state.isExpanded = false
            state.isPeeking = false
            state.isTrackPeek = false
            state.showsVolume = false
            state.search = nil
            shrinkWindow()
        }
        updateMouseHandling()
    }

    // MARK: Search

    private func handleSearch(_ event: SearchEvent) {
        switch event {
        case .open:
            startSearch()
        case .close:
            endSearch(thenCollapse: !isPointerOverPanel)
        case .textChanged(let text):
            state.search?.text = text
            scheduleLibrarySearch()
        case .submit:
            submitSearch()
        case .choose(let result):
            actions.playSearchResult(result)
            endSearch(thenCollapse: true)
        }
    }

    /// Opens the search field in place of the controls, and lets the panel take the
    /// keyboard while it's open.
    private func startSearch() {
        guard state.isExpanded, state.search == nil, let snapshot = model.snapshot,
              let target = SearchTarget.forApp(of: snapshot) else { return }
        hoverTask?.cancel()
        keyboardCloseTask?.cancel()
        let search = SearchState(target: target)
        let size = state.geometry.searchSize(width: state.expandedSize.width, resultRows: search.resultRows,
                                             showsHint: target.hint != nil)
        growWindow(toFit: size)
        withAnimation(.smooth(duration: 0.25)) {
            state.showsVolume = false
            state.search = search
            state.expandedSize = size
        }
        panel.acceptsKey = true
        panel.makeKey()
    }

    /// Closes the search field and gives the keyboard back to the app in front.
    private func endSearch(thenCollapse: Bool) {
        searchTask?.cancel()
        guard state.search != nil else { return }
        if thenCollapse {
            // Closes with the search still showing; `collapse` clears it at the end.
            collapse()
            return
        }
        relinquishKey()
        withAnimation(.smooth(duration: 0.25)) {
            state.search = nil
            (state.expandedSize, state.expandedBodyWidth) = panelSize(style: state.expandedStyle)
        }
    }

    /// Searches Music's library once typing pauses.
    private func scheduleLibrarySearch() {
        searchTask?.cancel()
        guard let search = state.search, search.target == .musicLibrary else { return }
        let query = search.text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            state.search?.results = nil
            state.search?.message = nil
            state.search?.isSearching = false
            resizeForSearch()
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.searchLibrary(query, thenPlayFirst: false)
        }
    }

    private func searchLibrary(_ query: String, thenPlayFirst: Bool) {
        state.search?.isSearching = true
        actions.searchLibrary(query) { [weak self] results in
            // Drop answers to a query that's since changed.
            guard let self, self.state.search?.text.trimmingCharacters(in: .whitespaces) == query else { return }
            self.state.search?.isSearching = false
            if thenPlayFirst, let first = results?.first {
                self.actions.playSearchResult(first)
                self.endSearch(thenCollapse: true)
                return
            }
            self.state.search?.results = results ?? []
            self.state.search?.message = results == nil
                ? "Couldn't search Music. Allow MusicNotch in Privacy & Security → Automation."
                : nil
            self.resizeForSearch()
        }
    }

    /// Return: plays Music's top result, or hands the query to the app or site.
    private func submitSearch() {
        guard let search = state.search else { return }
        let query = search.text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        guard search.target == .musicLibrary else {
            actions.handOffSearch(query, search.target)
            endSearch(thenCollapse: true)
            return
        }
        if let first = search.results?.first {
            actions.playSearchResult(first)
            endSearch(thenCollapse: true)
        } else {
            searchTask?.cancel()
            searchLibrary(query, thenPlayFirst: true)
        }
    }

    /// Fits the panel to the search field and whatever is below it.
    private func resizeForSearch() {
        guard let search = state.search else { return }
        let size = state.geometry.searchSize(width: state.expandedSize.width, resultRows: search.resultRows,
                                             showsHint: search.target.hint != nil)
        guard size != state.expandedSize else { return }
        growWindow(toFit: size)
        withAnimation(.smooth(duration: 0.25)) { state.expandedSize = size }
    }

    /// Makes the window big enough for `size` and the springs' overshoot. It doesn't shrink
    /// while open; the transparent part lets clicks through.
    private func growWindow(toFit size: CGSize) {
        let needed = CGSize(width: size.width + 2 * Self.overshootMargin, height: size.height + Self.overshootMargin)
        let current = panel.frame.size
        guard needed.width > current.width || needed.height > current.height else { return }
        setWindowSize(CGSize(width: max(needed.width, current.width), height: max(needed.height, current.height)))
    }

    /// The user clicked into another app while searching.
    private func panelResignedKey() {
        // A demo clip (`DemoScene`) holds still as focus returns to the terminal that ran it.
        guard state.search != nil, DemoScene.current == nil else { return }
        endSearch(thenCollapse: !isPointerOverPanel)
    }

    private var isPointerOverPanel: Bool {
        state.geometry.frame(for: state.expandedSize).contains(NSEvent.mouseLocation)
    }

    /// Gives the keyboard back to the app in front: the panel stops accepting it, and
    /// ordering the panel out and straight back in makes macOS hand it to that app again.
    private func relinquishKey() {
        panel.acceptsKey = false
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        space?.add(panel)
    }

    /// Room around the shape so springs (Bouncy, Pop, Bounce) can overshoot without being cut off.
    private static let overshootMargin: CGFloat = 28

    /// Resizes the window around the top center of the screen. The content has to move
    /// within the window to stay put on screen, so that layout pass runs right here,
    /// before any animation starts; otherwise the move gets animated and the shape
    /// appears to slide in from the left.
    private func setWindowSize(_ size: CGSize) {
        panel.disableScreenUpdatesUntilFlush()
        panel.setFrame(state.geometry.frame(for: size), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }
}

