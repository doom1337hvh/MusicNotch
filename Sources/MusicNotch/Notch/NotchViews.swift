import SwiftUI

struct NotchRootView: View {
    let model: NowPlaying
    let prefs: Preferences
    let state: NotchState
    let actions: NotchActions

    var body: some View {
        let geometry = state.geometry
        let expanded = state.isExpanded
        let peeking = state.isPeeking && !expanded
        // With nothing beside the closed notch, it's hidden inside the camera housing (or,
        // without a notch, an invisible target) until it opens.
        let hidesClosed = !prefs.showBesideNotch && !expanded && !peeking
        let barSize = peeking ? geometry.peekSize : geometry.closedSize(showsContent: prefs.showBesideNotch)
        let size = expanded ? state.expandedSize : barSize
        let compact = state.expandedStyle == .compact || state.isTrackPeek
        let sources = SourcesInfo(sessions: model.sessions, displayedID: model.displayedSessionID,
                                  canControl: model.canControlDisplayed)
        // On a closed notch with "Open on: Click", the artwork opens the notch like the rest
        // of it; otherwise it opens the playing app.
        let artworkTap: @MainActor () -> Void = {
            if !peeking && prefs.openTrigger == .click {
                state.onTap?()
            } else if prefs.clickArtworkOpensApp {
                actions.openSourceApp()
            }
        }
        let shape = NotchShape(
            topRadius: expanded ? (compact ? 12 : 14) : (geometry.hasNotch && !hidesClosed ? 6 : 0),
            bottomRadius: expanded ? (compact ? 18 : 22) : (geometry.hasNotch ? (hidesClosed ? 8 : 10) : geometry.height / 2)
        )

        ZStack(alignment: .top) {
            if let snapshot = model.snapshot {
                if expanded {
                    let volume = volumeControl(for: snapshot)
                    let seek = seekControl(for: snapshot, canControl: sources.canControl)
                    let modes = modesControl(for: snapshot)
                    let search = SearchControl(
                        target: prefs.showSearch ? SearchTarget.forApp(of: snapshot) : nil,
                        search: state.search,
                        send: { [state] event in state.onSearch?(event) }
                    )
                    Group {
                        if state.isTrackPeek {
                            TrackPeekView(snapshot: snapshot, prefs: prefs, geometry: geometry)
                        } else if compact {
                            CompactView(snapshot: snapshot, prefs: prefs, geometry: geometry, actions: actions,
                                        sources: sources, volume: volume, seek: seek, modes: modes,
                                        search: search, panelWidth: state.expandedSize.width)
                        } else {
                            ExpandedView(snapshot: snapshot, prefs: prefs, geometry: geometry, actions: actions,
                                         sources: sources, volume: volume, seek: seek, modes: modes,
                                         search: search, panelWidth: state.expandedSize.width)
                        }
                    }
                    .frame(width: state.expandedSize.width, height: state.expandedSize.height, alignment: .top)
                        .transition(.asymmetric(
                            insertion: prefs.effectiveOpenAnimation.contentArrival,
                            removal: .opacity.animation(.easeOut(duration: 0.12))
                        ))
                } else if !hidesClosed {
                    CollapsedView(snapshot: snapshot, prefs: prefs, geometry: geometry, actions: actions,
                                  sources: sources, isPeeking: peeking, onArtworkTap: artworkTap)
                        .frame(width: barSize.width, height: geometry.height)
                        .offset(x: state.contentOffset)
                        .transition(.opacity)
                }
            }
        }
        // The desktop-switch Blur blurs only the contents: blurring the shape too would soften
        // its top edge into a visible gap below the top of the screen.
        .blur(radius: state.appearContentBlur)
        // The content keeps its final size, centered at the top, and the growing shape
        // reveals it evenly on both sides instead of reflowing it on every frame.
        .frame(width: size.width, height: size.height, alignment: .top)
        // An invisible target still needs a little opacity to catch the pointer.
        .background(alignment: .top) {
            NotchBackground(shape: shape, isGlass: expanded && prefs.effectiveTheme == .glass,
                            housing: prefs.effectiveTheme == .glass && geometry.hasNotch
                                ? CGSize(width: geometry.notchWidth, height: geometry.height) : nil,
                            opacity: hidesClosed && !geometry.hasNotch ? 0.01 : 1)
        }
        .clipShape(shape)
        .contentShape(shape)
        // Desktop-switch Zoom and Bounce; at rest this does nothing.
        .scaleEffect(state.appearScale, anchor: .top)
        .onHover { state.onHover?($0) }
        // Buttons, icons and the artwork inside take their own clicks first.
        .onTapGesture { state.onTap?() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private func volumeControl(for snapshot: NowPlayingSnapshot) -> VolumeControl {
        let bundleID = snapshot.bundleID
        let state = state
        let actions = actions
        return VolumeControl(
            isSupported: AppVolume.supports(bundleID: bundleID),
            isShown: state.showsVolume && state.volumeBundleID == bundleID,
            level: state.volumeLevel ?? 0.5,
            isUnavailable: state.volumeUnavailable,
            tint: prefs.accent(for: snapshot),
            toggle: {
                if state.showsVolume && state.volumeBundleID == bundleID {
                    withAnimation(.smooth(duration: 0.2)) { state.showsVolume = false }
                    return
                }
                state.volumeBundleID = bundleID
                state.volumeUnavailable = false
                withAnimation(.smooth(duration: 0.2)) { state.showsVolume = true }
                actions.readVolume(bundleID) { level in
                    guard state.volumeBundleID == bundleID else { return }
                    state.volumeUnavailable = level == nil
                    if let level { state.volumeLevel = level }
                }
            },
            change: { level in
                state.volumeLevel = level
                actions.setVolume(bundleID, level)
            }
        )
    }

    private func seekControl(for snapshot: NowPlayingSnapshot, canControl: Bool) -> SeekControl {
        let state = state
        let actions = actions
        let duration = snapshot.duration ?? 0
        return SeekControl(
            isEnabled: canControl && snapshot.canSeek && duration > 0,
            dragFraction: state.scrubFraction,
            drag: { state.scrubFraction = $0 },
            end: { fraction in
                state.scrubFraction = nil
                actions.seek(fraction * duration)
                state.onScrubEnded?()
            }
        )
    }

    private func modesControl(for snapshot: NowPlayingSnapshot) -> ModesControl {
        let bundleID = snapshot.bundleID
        let state = state
        let actions = actions
        let current = state.modesBundleID == bundleID ? state.modes : nil
        let read = {
            actions.readModes(bundleID) { modes in
                guard state.modesBundleID == bundleID, let modes else { return }
                state.modes = modes
                state.modesUnavailable = false
            }
        }
        // Shows the change straight away, then what the app was actually set to: the state
        // shown may have been unknown (before access was first allowed) or out of date.
        let change: @MainActor (PlaybackModes, (String, @escaping @MainActor @Sendable (PlaybackModes?) -> Void) -> Void) -> Void = {
            changed, send in
            state.modesBundleID = bundleID
            state.modes = changed
            send(bundleID) { result in
                guard state.modesBundleID == bundleID else { return }
                guard let result else {
                    state.modes = current
                    state.modesUnavailable = true
                    return
                }
                state.modes = result
                state.modesUnavailable = false
            }
        }
        let shown = current ?? PlaybackModes(shuffle: false, repeatMode: .off)
        return ModesControl(
            isShown: prefs.showShuffleRepeat && AppPlaybackModes.supports(bundleID: bundleID),
            modes: current,
            isUnavailable: state.modesBundleID == bundleID && state.modesUnavailable,
            refresh: {
                if state.modesBundleID != bundleID {
                    state.modesBundleID = bundleID
                    state.modes = nil
                    state.modesUnavailable = false
                }
                read()
            },
            toggleShuffle: {
                change(PlaybackModes(shuffle: !shown.shuffle, repeatMode: shown.repeatMode), actions.toggleShuffle)
            },
            cycleRepeat: {
                let next = AppPlaybackModes.nextRepeat(after: shown.repeatMode, bundleID: bundleID)
                change(PlaybackModes(shuffle: shown.shuffle, repeatMode: next), actions.cycleRepeat)
            }
        )
    }
}

/// Shuffle and repeat buttons, for apps that support them (see `AppPlaybackModes`).
struct ModesControl {
    var isShown: Bool
    /// Nil until read; shown as off.
    var modes: PlaybackModes?
    var isUnavailable: Bool
    /// Reads the app's current modes, if MusicNotch is allowed to control it.
    var refresh: @MainActor () -> Void
    var toggleShuffle: @MainActor () -> Void
    var cycleRepeat: @MainActor () -> Void

    var shuffleButton: (symbol: String, isOn: Bool, help: String) {
        let on = modes?.shuffle == true
        return ("shuffle", on, help(on ? "Shuffle is on" : "Shuffle"))
    }

    var repeatButton: (symbol: String, isOn: Bool, help: String) {
        switch modes?.repeatMode ?? .off {
        case .off: ("repeat", false, help("Repeat"))
        case .all: ("repeat", true, help("Repeat is on"))
        case .one: ("repeat.1", true, help("Repeating this song"))
        }
    }

    private func help(_ text: String) -> String {
        isUnavailable
            ? "Allow MusicNotch to control this app in System Settings → Privacy & Security → Automation."
            : text
    }
}

/// Dragging the progress bar to jump to a position, for apps that accept it.
struct SeekControl {
    var isEnabled: Bool
    /// Where the bar is being dragged to, 0...1, while it's dragged.
    var dragFraction: Double?
    var drag: @MainActor (Double) -> Void
    /// Called on release, where the position is sent to the app.
    var end: @MainActor (Double) -> Void
}

/// The volume button and slider, for apps that have their own volume (see `AppVolume`).
struct VolumeControl {
    var isSupported: Bool
    var isShown: Bool
    var level: Double
    /// True if the app's volume couldn't be read, usually because Automation access was denied.
    var isUnavailable: Bool
    /// The slider's colour (see `Preferences.accent`), or nil for white.
    var tint: CGColor?
    var toggle: @MainActor () -> Void
    var change: @MainActor (Double) -> Void
}

/// Artwork on the left of the notch, equalizer on the right. While peeking, skip buttons
/// sit between them and the camera housing.
private struct CollapsedView: View {
    let snapshot: NowPlayingSnapshot
    let prefs: Preferences
    let geometry: NotchGeometry
    let actions: NotchActions
    let sources: SourcesInfo
    let isPeeking: Bool
    let onArtworkTap: @MainActor () -> Void

    var body: some View {
        let side = geometry.height - 12
        HStack(spacing: 0) {
            ArtworkView(artwork: prefs.effectiveArtwork ? snapshot.artwork : nil, size: side, cornerRadius: 5)
                // With several apps playing media, a small badge says which one this is.
                .overlay(alignment: .bottomTrailing) {
                    if sources.hasSeveral {
                        Image(nsImage: AppIcons.icon(for: snapshot.sourceAppBundleID))
                            .resizable()
                            .frame(width: 11, height: 11)
                            .offset(x: 3, y: 3)
                    }
                }
                .onTapGesture { onArtworkTap() }
                .frame(width: geometry.wingWidth)
            if isPeeking {
                ControlButton(symbol: "backward.fill", size: 12, width: geometry.peekButtonWidth,
                              height: geometry.height, enabled: sources.canControl, action: actions.previous)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
            Spacer(minLength: 0)
            if isPeeking {
                ControlButton(symbol: "forward.fill", size: 12, width: geometry.peekButtonWidth,
                              height: geometry.height, enabled: sources.canControl, action: actions.next)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
            EqualizerView(isPlaying: snapshot.isPlaying, animated: prefs.effectiveEqualizerAnimation,
                          color: prefs.accent(for: snapshot))
                .frame(width: 16, height: side * 0.6)
                .frame(width: geometry.wingWidth)
        }
        .padding(.horizontal, geometry.hasNotch ? 6 : 0)
        .frame(height: geometry.height)
    }
}

/// The apps with media, for the source icons and the collapsed badge.
struct SourcesInfo {
    var sessions: [MediaSession]
    var displayedID: String?
    var canControl: Bool

    var hasSeveral: Bool { sessions.count > 1 }
}

/// App icons by bundle ID, looked up once.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            ?? NSImage()
        cache[bundleID] = icon
        return icon
    }
}

/// The strip beside the camera housing at the top of an open panel. When several apps
/// have media, their icons sit here, split across both sides of the camera housing like
/// the artwork and bars below. The panel is sized to fit them; if more apps appear while
/// it's open, the last slot becomes "+N", which shows the next hidden one.
private struct TopBand: View {
    let geometry: NotchGeometry
    let panelWidth: CGFloat
    let sources: SourcesInfo
    let select: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if sources.hasSeveral {
                let perSide = geometry.sourceIconsPerSide(panelWidth: panelWidth)
                let slots = geometry.hasNotch ? 2 * perSide : perSide
                let all = sources.sessions
                let overflow = all.count > slots
                let shown = Array(all.prefix(overflow ? slots - 1 : slots))
                let hidden = Array(all.dropFirst(shown.count))
                // On a notched screen the first half goes left of the camera housing, the rest right.
                let leftCount = geometry.hasNotch ? (shown.count + (overflow ? 1 : 0) + 1) / 2 : shown.count
                let left = Array(shown.prefix(leftCount))
                let right = Array(shown.dropFirst(leftCount))

                SourceIcons(sessions: left, displayedID: sources.displayedID, select: select)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    SourceIcons(sessions: right, displayedID: sources.displayedID, select: select)
                    if let next = hidden.first {
                        Text("+\(hidden.count)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(minWidth: 16, minHeight: 16)
                            .contentShape(Rectangle())
                            .onTapGesture { select(next.id) }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: geometry.height)
    }
}

/// Icons for some apps with media; the one shown is highlighted. Click another to show it.
private struct SourceIcons: View {
    let sessions: [MediaSession]
    let displayedID: String?
    let select: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(sessions) { session in
                let isShown = session.id == displayedID
                Image(nsImage: AppIcons.icon(for: session.snapshot.sourceAppBundleID))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .opacity(isShown ? 1 : 0.45)
                    .overlay(alignment: .bottom) {
                        if isShown {
                            Capsule().fill(.white).frame(width: 6, height: 2).offset(y: 5)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { select(session.id) }
                    .help(session.snapshot.title)
            }
        }
    }
}

/// Paddings and row heights must add up to `NotchGeometry.expandedSize`.
private struct ExpandedView: View {
    let snapshot: NowPlayingSnapshot
    let prefs: Preferences
    let geometry: NotchGeometry
    let actions: NotchActions
    let sources: SourcesInfo
    let volume: VolumeControl
    let seek: SeekControl
    let modes: ModesControl
    let search: SearchControl
    let panelWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            TopBand(geometry: geometry, panelWidth: panelWidth, sources: sources, select: actions.selectSource)
            if let open = search.search {
                SearchPanelView(search: open, send: search.send)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            } else {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    ArtworkView(artwork: prefs.effectiveArtwork ? snapshot.artwork : nil, size: 56, cornerRadius: 10)
                        .onTapGesture {
                            if prefs.clickArtworkOpensApp { actions.openSourceApp() }
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        if let artist = snapshot.artist {
                            Text(artist)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    EqualizerView(isPlaying: snapshot.isPlaying, animated: prefs.effectiveEqualizerAnimation,
                          color: prefs.accent(for: snapshot))
                        .frame(width: 16, height: 14)
                }
                .frame(height: 56)

                if prefs.effectiveProgressBar, let duration = snapshot.duration {
                    ProgressRow(snapshot: snapshot, duration: duration, seek: seek, tint: prefs.accent(for: snapshot))
                        .frame(height: 18)
                }

                ZStack {
                    if volume.isShown {
                        VolumeRow(volume: volume)
                            .padding(.horizontal, 36)
                            .transition(.opacity)
                    } else {
                        HStack(spacing: modes.isShown ? 16 : 30) {
                            if modes.isShown {
                                ModeButton(modes.shuffleButton, size: 13, width: 32, action: modes.toggleShuffle)
                            }
                            ControlButton(symbol: "backward.fill", size: 16, enabled: sources.canControl,
                                          action: actions.previous)
                            ControlButton(symbol: snapshot.isPlaying ? "pause.fill" : "play.fill", size: 22,
                                          enabled: sources.canControl, action: actions.playPause)
                            ControlButton(symbol: "forward.fill", size: 16, enabled: sources.canControl,
                                          action: actions.next)
                            if modes.isShown {
                                ModeButton(modes.repeatButton, size: 13, width: 32, action: modes.cycleRepeat)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if search.isAvailable {
                        SearchButton(search: search, size: 13)
                    }
                }
                .overlay(alignment: .trailing) {
                    if volume.isSupported {
                        VolumeButton(volume: volume, size: 13)
                    }
                }
                .frame(height: 30)
                .task(id: modes.isShown ? snapshot.bundleID : nil) {
                    if modes.isShown { modes.refresh() }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .transition(.opacity)
            }
        }
    }
}

/// The brief banner shown when the track changes ("Show new tracks"). Paddings and row
/// heights must add up to `NotchGeometry.trackPeekSize`.
private struct TrackPeekView: View {
    let snapshot: NowPlayingSnapshot
    let prefs: Preferences
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            // Nothing is drawn under the camera housing.
            Color.clear.frame(height: geometry.height)
            HStack(spacing: 10) {
                ArtworkView(artwork: prefs.effectiveArtwork ? snapshot.artwork : nil, size: 36, cornerRadius: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    if let artist = snapshot.artist {
                        Text(artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                EqualizerView(isPlaying: snapshot.isPlaying, animated: prefs.effectiveEqualizerAnimation,
                          color: prefs.accent(for: snapshot))
                    .frame(width: 14, height: 12)
            }
            .frame(height: 36)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }
}

/// A smaller version of the full panel: one row of artwork, title and controls, with a thin
/// progress line. Paddings and row heights must add up to `NotchGeometry.compactSize`.
private struct CompactView: View {
    let snapshot: NowPlayingSnapshot
    let prefs: Preferences
    let geometry: NotchGeometry
    let actions: NotchActions
    let sources: SourcesInfo
    let volume: VolumeControl
    let seek: SeekControl
    let modes: ModesControl
    let search: SearchControl
    let panelWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            TopBand(geometry: geometry, panelWidth: panelWidth, sources: sources, select: actions.selectSource)
            if let open = search.search {
                SearchPanelView(search: open, send: search.send)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            } else {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ArtworkView(artwork: prefs.effectiveArtwork ? snapshot.artwork : nil, size: 40, cornerRadius: 8)
                        .onTapGesture {
                            if prefs.clickArtworkOpensApp { actions.openSourceApp() }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                        if let artist = snapshot.artist {
                            Text(artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    if volume.isShown {
                        VolumeRow(volume: volume)
                            .frame(width: 104)
                            .transition(.opacity)
                    } else {
                        // Keep `NotchGeometry.compactSize` in sync with the mode buttons' width.
                        HStack(spacing: 0) {
                            if modes.isShown {
                                ModeButton(modes.shuffleButton, size: 10.5, width: 26, height: 28,
                                           action: modes.toggleShuffle)
                            }
                            ControlButton(symbol: "backward.fill", size: 12, width: 28, height: 28,
                                          enabled: sources.canControl, action: actions.previous)
                            ControlButton(symbol: snapshot.isPlaying ? "pause.fill" : "play.fill", size: 15,
                                          width: 30, height: 28, enabled: sources.canControl, action: actions.playPause)
                            ControlButton(symbol: "forward.fill", size: 12, width: 28, height: 28,
                                          enabled: sources.canControl, action: actions.next)
                            if modes.isShown {
                                ModeButton(modes.repeatButton, size: 10.5, width: 26, height: 28,
                                           action: modes.cycleRepeat)
                            }
                        }
                        .transition(.opacity)
                    }
                    // Keep `NotchGeometry.compactSize` in sync with these buttons' widths.
                    if search.isAvailable {
                        SearchButton(search: search, size: 11)
                    }
                    if volume.isSupported {
                        VolumeButton(volume: volume, size: 11)
                    }
                }
                .frame(height: 40)
                .task(id: modes.isShown ? snapshot.bundleID : nil) {
                    if modes.isShown { modes.refresh() }
                }

                if prefs.effectiveProgressBar, let duration = snapshot.duration {
                    ProgressLine(snapshot: snapshot, duration: duration, seek: seek, tint: prefs.accent(for: snapshot))
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .transition(.opacity)
            }
        }
    }
}

private struct ArtworkView: View {
    let artwork: Artwork?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let artwork {
                Image(decorative: artwork.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Ticks once a second, and only while playing and visible.
private struct ProgressRow: View {
    let snapshot: NowPlayingSnapshot
    let duration: TimeInterval
    let seek: SeekControl
    let tint: CGColor?

    var body: some View {
        if snapshot.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                row(at: context.date)
            }
        } else {
            row(at: .now)
        }
    }

    private func row(at date: Date) -> some View {
        // While the bar is dragged, the times show where it would jump to.
        let elapsed = seek.dragFraction.map { $0 * duration } ?? snapshot.elapsed(at: date) ?? 0
        let fraction = min(max(elapsed / duration, 0), 1)
        // Hour-long tracks (mixes, podcasts) show h:mm:ss, which needs more room.
        let labelWidth: CGFloat = duration >= 3600 ? 52 : 38
        return HStack(spacing: 8) {
            Text(Self.format(elapsed))
                .frame(width: labelWidth, alignment: .leading)
            SeekableTrack(fraction: fraction, barHeight: 4, seek: seek, tint: tint)
            Text("-" + Self.format(duration - elapsed))
                .frame(width: labelWidth, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Just the progress bar, for the Compact panel. Ticks once a second, only while playing.
private struct ProgressLine: View {
    let snapshot: NowPlayingSnapshot
    let duration: TimeInterval
    let seek: SeekControl
    let tint: CGColor?

    var body: some View {
        if snapshot.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                SeekableTrack(fraction: fraction(at: context.date), barHeight: 3, seek: seek, tint: tint)
            }
        } else {
            SeekableTrack(fraction: fraction(at: .now), barHeight: 3, seek: seek, tint: tint)
        }
    }

    private func fraction(at date: Date) -> Double {
        seek.dragFraction ?? min(max((snapshot.elapsed(at: date) ?? 0) / duration, 0), 1)
    }
}

/// The progress bar. For apps that accept it, click or drag anywhere along it to jump
/// there; the position is sent on release. It thickens while dragged.
private struct SeekableTrack: View {
    let fraction: Double
    let barHeight: CGFloat
    let seek: SeekControl
    let tint: CGColor?

    var body: some View {
        let dragging = seek.dragFraction != nil
        ProgressTrack(fraction: fraction, highlighted: dragging, tint: tint)
            .frame(height: dragging ? barHeight + 2 : barHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A target taller than the thin bar, so it's easy to grab.
            .overlay {
                if seek.isEnabled {
                    GeometryReader { proxy in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { seek.drag(Self.fraction(of: $0.location.x, in: proxy.size.width)) }
                                    .onEnded { seek.end(Self.fraction(of: $0.location.x, in: proxy.size.width)) }
                            )
                    }
                    .frame(height: 16)
                }
            }
    }

    private static func fraction(of x: CGFloat, in width: CGFloat) -> Double {
        width > 0 ? min(max(x / width, 0), 1) : 0
    }
}

private struct ProgressTrack: View {
    let fraction: Double
    var highlighted = false
    /// The artwork's colour, or nil for white.
    var tint: CGColor?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(tint.map { Color(cgColor: $0) } ?? .white.opacity(highlighted ? 1 : 0.85))
                    .frame(width: proxy.size.width * fraction)
            }
        }
    }
}

/// Swaps the playback buttons for the volume slider and back.
private struct VolumeButton: View {
    let volume: VolumeControl
    let size: CGFloat

    var body: some View {
        ControlButton(symbol: volume.isShown ? "speaker.wave.2.circle.fill" : "speaker.wave.2.fill",
                      size: size, width: 26, height: 28, action: volume.toggle)
            .help(volume.isShown ? "Back to playback controls" : "Volume")
    }
}

private struct VolumeRow: View {
    let volume: VolumeControl

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "speaker.fill")
            VolumeSlider(level: volume.level, tint: volume.tint, onChange: volume.change)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.white.opacity(0.7))
        .opacity(volume.isUnavailable ? 0.35 : 1)
        .allowsHitTesting(!volume.isUnavailable)
        .help(volume.isUnavailable
              ? "Allow MusicNotch to control this app in System Settings → Privacy & Security → Automation."
              : "")
    }
}

/// Drawn like the progress bar, with a knob; drag or click anywhere on it.
private struct VolumeSlider: View {
    let level: Double
    /// The artwork's colour, or nil for white.
    let tint: CGColor?
    let onChange: @MainActor (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: 4)
                Capsule().fill(tint.map { Color(cgColor: $0) } ?? .white.opacity(0.85))
                    .frame(width: max(4, width * level), height: 4)
                Circle().fill(.white).frame(width: 10, height: 10).offset(x: width * level - 5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onChange(min(max(value.location.x / width, 0), 1)) }
            )
        }
        .frame(height: 16)
    }
}

/// Shuffle or repeat: dimmed while off, with a dot underneath while on.
private struct ModeButton: View {
    let symbol: String
    let isOn: Bool
    let help: String
    let size: CGFloat
    let width: CGFloat
    let height: CGFloat
    let action: @MainActor () -> Void

    init(_ button: (symbol: String, isOn: Bool, help: String), size: CGFloat, width: CGFloat,
         height: CGFloat = 30, action: @escaping @MainActor () -> Void) {
        (symbol, isOn, help) = button
        self.size = size
        self.width = width
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .opacity(isOn ? 1 : 0.4)
                .frame(width: width, height: height)
                .overlay(alignment: .bottom) {
                    if isOn {
                        Circle().fill(.white).frame(width: 3, height: 3).padding(.bottom, 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(.white)
        .help(help)
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    var width: CGFloat = 40
    var height: CGFloat = 30
    /// Off when the shown app can't be controlled (see `NowPlaying.canControlDisplayed`).
    var enabled = true
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(.white)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}
