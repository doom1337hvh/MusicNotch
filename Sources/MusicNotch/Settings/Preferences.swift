import CoreGraphics
import Foundation
import Observation

enum UpdateBatching: Int, CaseIterable, Identifiable {
    case instant = 0
    case balanced = 150
    case batterySaver = 1000

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .instant: "Instant"
        case .balanced: "Balanced"
        case .batterySaver: "Battery saver"
        }
    }
}

enum EqualizerAnimation: Int, CaseIterable, Identifiable {
    case always = 0
    case whenPluggedIn = 1
    case never = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .always: "Always"
        case .whenPluggedIn: "Only when plugged in"
        case .never: "Never"
        }
    }
}

/// How the notch appears on a new desktop (see `SpaceSwitchAnimation.motion`).
/// (Raw value 5 belonged to the removed Drop; it falls back to Fade.)
enum SpaceSwitchAnimation: Int, CaseIterable, Identifiable {
    case fade = 1
    case slide = 0
    /// Grows the closed notch out from behind the camera housing.
    case expand = 7
    case zoom = 3
    case bounce = 4
    case blur = 6
    case none = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fade: "Fade"
        case .slide: "Slide"
        case .expand: "Expand"
        case .zoom: "Zoom"
        case .bounce: "Bounce"
        case .blur: "Blur"
        case .none: "None"
        }
    }
}

/// When the notch steps aside for a full-screen app.
enum FullScreenHiding: Int, CaseIterable, Identifiable {
    case never = 0
    /// Only when the app playing media is the full-screen one, like a video.
    case playingApp = 1
    case anyApp = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .playingApp: "When the playing app is"
        case .anyApp: "In any full-screen app"
        }
    }
}

/// What the notch opens into when you hover over it.
enum NotchStyle: Int, CaseIterable, Identifiable {
    /// Widens sideways with skip buttons beside the artwork and bars.
    case minimal = 0
    /// A small panel: one row with artwork, title and controls.
    case compact = 1
    /// The full panel.
    case full = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .minimal: "Minimal"
        case .compact: "Compact"
        case .full: "Full"
        }
    }
}

/// Whether the notch opens on hover or needs a click, for all styles.
enum NotchOpenTrigger: Int, CaseIterable, Identifiable {
    case hover = 0
    case click = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .hover: "Hover"
        case .click: "Click"
        }
    }
}

/// What the open notch is made of.
enum NotchTheme: Int, CaseIterable, Identifiable {
    case black = 0
    /// Black over the camera housing, fading into frosted glass below it.
    case glass = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .black: "Black"
        case .glass: "Glass"
        }
    }
}

/// The colour of the equalizer, progress bar and volume slider.
enum AccentColour: Int, CaseIterable, Identifiable {
    /// The artwork's most vivid colour.
    case artwork = 0
    case white = 1
    /// `Preferences.solidColour`.
    case solid = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .artwork: "From the artwork"
        case .white: "White"
        case .solid: "Solid colour"
        }
    }
}

/// User settings, saved to UserDefaults.
///
/// Views and the notch read the `effective…` values, which apply low-resource mode
/// and, for the equalizer, the power source.
@Observable @MainActor
final class Preferences {
    private enum Key {
        static let clickArtworkOpensApp = "clickArtworkOpensApp"
        static let notchStyle = "notchStyle"
        static let openTrigger = "notchOpenTrigger"
        static let theme = "notchTheme"
        static let showTrackPeek = "showTrackPeek"
        static let showBesideNotch = "showBesideNotch"
        static let showShuffleRepeat = "showShuffleRepeat"
        static let showSearch = "showSearch"
        static let showSoundApps = "showSoundApps"
        static let hideInFullScreen = "hideInFullScreen"
        static let openFromCameraOnly = "openFromCameraOnly"
        static let showOnExternalDisplays = "showOnExternalDisplays"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let lowResourceMode = "lowResourceMode"
        static let followLowPowerMode = "followLowPowerMode"
        static let accentColour = "accentColour"
        static let solidColour = "solidColour"
        static let equalizerAnimation = "equalizerAnimation"
        static let showArtwork = "showArtwork"
        static let showProgressBar = "showProgressBar"
        static let openAnimation = "openAnimation"
        /// Replaced by `openAnimation`; "off" carries over as Instant.
        static let legacyAnimateTransitions = "animateTransitions"
        static let spaceSwitchAnimation = "spaceSwitchAnimation"
        static let hideDuringSwipes = "hideDuringSwipes"
        static let updateBatching = "updateBatching"
        static let hotkeys = "hotkeys"
    }

    @ObservationIgnored var onAdapterOptionsChange: (() -> Void)?
    @ObservationIgnored var onDisplayOptionsChange: (() -> Void)?
    @ObservationIgnored var onMenuBarIconChange: (() -> Void)?
    @ObservationIgnored var onSwipeOptionChange: (() -> Void)?
    @ObservationIgnored var onFullScreenOptionChange: (() -> Void)?
    @ObservationIgnored var onHotkeysChange: (() -> Void)?
    @ObservationIgnored var onSoundAppsChange: (() -> Void)?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let power = PowerMonitor()

    var clickArtworkOpensApp: Bool {
        didSet { defaults.set(clickArtworkOpensApp, forKey: Key.clickArtworkOpensApp) }
    }
    var notchStyle: NotchStyle {
        didSet { defaults.set(notchStyle.rawValue, forKey: Key.notchStyle) }
    }
    var openTrigger: NotchOpenTrigger {
        didSet { defaults.set(openTrigger.rawValue, forKey: Key.openTrigger) }
    }
    var theme: NotchTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }
    /// The artwork and equalizer beside the closed notch. Off, the closed notch shows nothing
    /// until it's hovered over, like the plain camera housing.
    var showBesideNotch: Bool {
        didSet {
            defaults.set(showBesideNotch, forKey: Key.showBesideNotch)
            onDisplayOptionsChange?()
        }
    }
    /// Briefly opens the notch to show a new track when the song changes.
    var showTrackPeek: Bool {
        didSet { defaults.set(showTrackPeek, forKey: Key.showTrackPeek) }
    }
    /// Shuffle and repeat buttons in the open panel, for apps that support them (Spotify, Music).
    var showShuffleRepeat: Bool {
        didSet { defaults.set(showShuffleRepeat, forKey: Key.showShuffleRepeat) }
    }
    /// A search button in the Compact and Full panels, for apps that can be searched.
    var showSearch: Bool {
        didSet { defaults.set(showSearch, forKey: Key.showSearch) }
    }
    /// Apps playing sound without Now Playing, like Teams or games (see `SoundApps`).
    var showSoundApps: Bool {
        didSet {
            defaults.set(showSoundApps, forKey: Key.showSoundApps)
            onSoundAppsChange?()
        }
    }
    /// Only the camera area opens the closed notch; the parts beside it let the pointer
    /// through to the menu bar.
    var openFromCameraOnly: Bool {
        didSet {
            defaults.set(openFromCameraOnly, forKey: Key.openFromCameraOnly)
            onDisplayOptionsChange?()
        }
    }
    var hideInFullScreen: FullScreenHiding {
        didSet {
            defaults.set(hideInFullScreen.rawValue, forKey: Key.hideInFullScreen)
            onFullScreenOptionChange?()
        }
    }
    var showOnExternalDisplays: Bool {
        didSet {
            defaults.set(showOnExternalDisplays, forKey: Key.showOnExternalDisplays)
            onDisplayOptionsChange?()
        }
    }
    var showMenuBarIcon: Bool {
        didSet {
            defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon)
            onMenuBarIconChange?()
        }
    }
    var lowResourceMode: Bool {
        didSet {
            defaults.set(lowResourceMode, forKey: Key.lowResourceMode)
            onAdapterOptionsChange?()
        }
    }
    var equalizerAnimation: EqualizerAnimation {
        didSet { defaults.set(equalizerAnimation.rawValue, forKey: Key.equalizerAnimation) }
    }
    /// Low-resource mode also turns on while macOS's Low Power Mode is on.
    var followLowPowerMode: Bool {
        didSet {
            defaults.set(followLowPowerMode, forKey: Key.followLowPowerMode)
            onAdapterOptionsChange?()
        }
    }
    var accentColour: AccentColour {
        didSet { defaults.set(accentColour.rawValue, forKey: Key.accentColour) }
    }
    /// The colour for `AccentColour.solid`.
    var solidColour: CGColor {
        didSet { defaults.set(Self.components(of: solidColour), forKey: Key.solidColour) }
    }
    var showArtwork: Bool {
        didSet {
            defaults.set(showArtwork, forKey: Key.showArtwork)
            onAdapterOptionsChange?()
        }
    }
    var showProgressBar: Bool {
        didSet { defaults.set(showProgressBar, forKey: Key.showProgressBar) }
    }
    var openAnimation: OpenAnimation {
        didSet { defaults.set(openAnimation.rawValue, forKey: Key.openAnimation) }
    }
    var spaceSwitchAnimation: SpaceSwitchAnimation {
        didSet { defaults.set(spaceSwitchAnimation.rawValue, forKey: Key.spaceSwitchAnimation) }
    }
    /// Uses the Input Monitoring permission to hide the notch as soon as a swipe starts.
    var hideDuringSwipes: Bool {
        didSet {
            defaults.set(hideDuringSwipes, forKey: Key.hideDuringSwipes)
            onSwipeOptionChange?()
        }
    }
    var updateBatching: UpdateBatching {
        didSet {
            defaults.set(updateBatching.rawValue, forKey: Key.updateBatching)
            onAdapterOptionsChange?()
        }
    }
    /// Keyboard shortcuts that work in any app. None by default.
    var hotkeys: [HotkeyAction: Hotkey] {
        didSet {
            let byName = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(byName), forKey: Key.hotkeys)
            onHotkeysChange?()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        Self.migrateLegacySettings(defaults)
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        clickArtworkOpensApp = bool(Key.clickArtworkOpensApp, true)
        notchStyle = (defaults.object(forKey: Key.notchStyle) as? Int)
            .flatMap(NotchStyle.init(rawValue:)) ?? .compact
        openTrigger = (defaults.object(forKey: Key.openTrigger) as? Int)
            .flatMap(NotchOpenTrigger.init(rawValue:)) ?? .hover
        theme = (defaults.object(forKey: Key.theme) as? Int).flatMap(NotchTheme.init(rawValue:)) ?? .glass
        showTrackPeek = bool(Key.showTrackPeek, true)
        showBesideNotch = bool(Key.showBesideNotch, true)
        showShuffleRepeat = bool(Key.showShuffleRepeat, true)
        showSearch = bool(Key.showSearch, true)
        showSoundApps = bool(Key.showSoundApps, true)
        openFromCameraOnly = bool(Key.openFromCameraOnly, true)
        hideInFullScreen = (defaults.object(forKey: Key.hideInFullScreen) as? Int)
            // Never by default: macOS can't tell a full-screen video from a browser that's in
            // full screen, so hiding would also hide it whenever that browser plays anything.
            .flatMap(FullScreenHiding.init(rawValue:)) ?? .never
        showOnExternalDisplays = bool(Key.showOnExternalDisplays, false)
        showMenuBarIcon = bool(Key.showMenuBarIcon, true)
        lowResourceMode = bool(Key.lowResourceMode, false)
        followLowPowerMode = bool(Key.followLowPowerMode, true)
        accentColour = (defaults.object(forKey: Key.accentColour) as? Int)
            .flatMap(AccentColour.init(rawValue:)) ?? .artwork
        solidColour = (defaults.array(forKey: Key.solidColour) as? [Double])
            .flatMap(Self.colour(from:)) ?? Self.defaultSolidColour
        equalizerAnimation = (defaults.object(forKey: Key.equalizerAnimation) as? Int)
            .flatMap(EqualizerAnimation.init(rawValue:)) ?? .whenPluggedIn
        showArtwork = bool(Key.showArtwork, true)
        showProgressBar = bool(Key.showProgressBar, true)
        openAnimation = (defaults.object(forKey: Key.openAnimation) as? Int)
            .flatMap(OpenAnimation.init(rawValue:))
            ?? (bool(Key.legacyAnimateTransitions, true) ? .bouncy : .instant)
        spaceSwitchAnimation = (defaults.object(forKey: Key.spaceSwitchAnimation) as? Int)
            .flatMap(SpaceSwitchAnimation.init(rawValue:)) ?? .fade
        hideDuringSwipes = bool(Key.hideDuringSwipes, false)
        updateBatching = (defaults.object(forKey: Key.updateBatching) as? Int)
            .flatMap(UpdateBatching.init(rawValue:)) ?? .balanced
        let savedHotkeys = defaults.data(forKey: Key.hotkeys)
            .flatMap { try? JSONDecoder().decode([String: Hotkey].self, from: $0) } ?? [:]
        hotkeys = Dictionary(uniqueKeysWithValues: savedHotkeys.compactMap { name, hotkey in
            HotkeyAction(rawValue: name).map { ($0, hotkey) }
        })
        // Low Power Mode can switch low-resource mode, which changes what the adapter sends.
        power.onLowPowerModeChange = { [weak self] in
            guard let self, followLowPowerMode, !lowResourceMode else { return }
            onAdapterOptionsChange?()
        }
    }

    /// Builds from before the first release used the bundle ID "local.MusicNotch"; their
    /// settings move over once.
    private static func migrateLegacySettings(_ defaults: UserDefaults) {
        let legacy = "local.MusicNotch"
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID != legacy,
              defaults.persistentDomain(forName: bundleID)?.isEmpty ?? true,
              let settings = defaults.persistentDomain(forName: legacy), !settings.isEmpty
        else { return }
        defaults.setPersistentDomain(settings, forName: bundleID)
        defaults.removePersistentDomain(forName: legacy)
    }

    /// Low-resource mode is in effect: switched on, or on for now because of Low Power Mode.
    var isLowResource: Bool { lowResourceMode || isLowResourceForLowPowerMode }
    /// Low-resource mode is on only because macOS's Low Power Mode is.
    var isLowResourceForLowPowerMode: Bool { !lowResourceMode && followLowPowerMode && power.isLowPowerMode }

    /// The colour for the equalizer and bars; nil for white, including while the artwork
    /// they'd take it from isn't shown or has no colour.
    func accent(for snapshot: NowPlayingSnapshot) -> CGColor? {
        switch accentColour {
        case .artwork: effectiveArtwork ? snapshot.artwork?.tint : nil
        case .white: nil
        case .solid: solidColour
        }
    }

    static let defaultSolidColour = CGColor(srgbRed: 1, green: 0.216, blue: 0.373, alpha: 1)

    /// Saved as sRGB red, green and blue.
    private static func components(of colour: CGColor) -> [Double] {
        let sRGB = colour.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        return (sRGB?.components ?? []).prefix(3).map(Double.init)
    }

    private static func colour(from components: [Double]) -> CGColor? {
        guard components.count == 3 else { return nil }
        return CGColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
    }

    /// The animated bars are the app's only ongoing energy cost (the window server redraws
    /// them while music plays), so by default they stop on battery and in Low Power Mode.
    var effectiveEqualizerAnimation: Bool {
        guard !isLowResource else { return false }
        switch equalizerAnimation {
        case .always: return true
        case .whenPluggedIn: return !power.isOnBattery && !power.isLowPowerMode
        case .never: return false
        }
    }
    /// Glass makes the window server blur what's behind the open notch, so low-resource
    /// mode keeps it black.
    var effectiveTheme: NotchTheme { isLowResource ? .black : theme }
    var effectiveArtwork: Bool { showArtwork && !isLowResource }
    var effectiveProgressBar: Bool { showProgressBar && !isLowResource }
    var effectiveOpenAnimation: OpenAnimation { isLowResource ? .instant : openAnimation }
    var effectiveSpaceSwitchAnimation: SpaceSwitchAnimation { isLowResource ? .none : spaceSwitchAnimation }
    var effectiveBatching: UpdateBatching { isLowResource ? .batterySaver : updateBatching }

    var adapterOptions: AdapterOptions {
        AdapterOptions(includeArtwork: effectiveArtwork, debounceMilliseconds: effectiveBatching.rawValue)
    }
}
