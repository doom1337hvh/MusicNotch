import AppKit

/// Reports which way the desktop moved when the user switches Spaces, e.g. with a
/// three-finger swipe. Only runs when macOS posts a Space change, so it costs nothing while idle.
@MainActor
final class SpaceObserver {
    enum Direction {
        /// To the Space on the right; the desktop slides left.
        case forward
        /// To the Space on the left; the desktop slides right.
        case backward
    }

    /// Called after a switch with the display's UUID (nil means every display) and the
    /// direction, if known.
    var onSwitch: ((_ displayUUID: String?, _ direction: Direction?) -> Void)?

    /// Displays (by UUID, or "Main" when they share Spaces) currently showing a full-screen app.
    private(set) var fullScreenDisplays: Set<String> = []

    /// The current Space on each display and its position, keyed by display UUID.
    private var current: [String: CurrentSpace]

    init() {
        current = Self.readCurrentSpaces()
        fullScreenDisplays = Self.fullScreen(current)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        }
    }

    func isFullScreen(displayUUID: String?) -> Bool {
        fullScreenDisplays.contains("Main") || displayUUID.map(fullScreenDisplays.contains) == true
    }

    /// Whether a swipe in `direction` lands on a full-screen app's desktop, on any display.
    func swipeLandsOnFullScreen(_ direction: Direction) -> Bool {
        swipeLands(direction) { $0 == Self.fullScreenType }
    }

    /// Whether a swipe in `direction` lands on an ordinary desktop, on any display.
    func swipeLandsOnDesktop(_ direction: Direction) -> Bool {
        swipeLands(direction) { $0 != Self.fullScreenType }
    }

    private func swipeLands(_ direction: Direction, on type: (Int) -> Bool) -> Bool {
        Self.readCurrentSpaces().values.contains { space in
            let target = space.index + (direction == .forward ? 1 : -1)
            return space.types.indices.contains(target) && type(space.types[target])
        }
    }

    private func activeSpaceChanged() {
        let spaces = Self.readCurrentSpaces()
        defer { current = spaces }
        fullScreenDisplays = Self.fullScreen(spaces)
        guard !spaces.isEmpty else {
            // The Space order isn't available: every display may have changed, direction unknown.
            onSwitch?(nil, nil)
            return
        }
        for (display, now) in spaces {
            let previous = current[display]
            guard previous?.space != now.space else { continue }
            var direction: Direction?
            if let previous, previous.index != now.index {
                direction = now.index > previous.index ? .forward : .backward
            }
            // With "Displays have separate Spaces" off, all screens share one entry called "Main".
            onSwitch?(display == "Main" ? nil : display, direction)
        }
    }

    // macOS has no public API for the order of Spaces, so this reads it from SkyLight,
    // the private window-server framework Mission Control uses. If a future macOS
    // removes these functions, the lookups fail and the notch fades in instead of sliding.
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let mainConnectionID = dlsym(skyLight, "SLSMainConnectionID")
        .map { unsafeBitCast($0, to: MainConnectionID.self) }
    private static let copyManagedDisplaySpaces = dlsym(skyLight, "SLSCopyManagedDisplaySpaces")
        .map { unsafeBitCast($0, to: CopyManagedDisplaySpaces.self) }

    private struct CurrentSpace {
        var space: Int
        var index: Int
        var isFullScreen: Bool
        /// Every Space's type on this display, in order.
        var types: [Int]
    }

    /// A full-screen app's Space; 0 is an ordinary desktop.
    private static let fullScreenType = 4

    private static func fullScreen(_ spaces: [String: CurrentSpace]) -> Set<String> {
        Set(spaces.filter(\.value.isFullScreen).keys)
    }

    private static func readCurrentSpaces() -> [String: CurrentSpace] {
        guard let mainConnectionID, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue() as? [[String: Any]]
        else { return [:] }
        var result: [String: CurrentSpace] = [:]
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int,
                  let spaces = display["Spaces"] as? [[String: Any]],
                  let index = spaces.firstIndex(where: { $0["ManagedSpaceID"] as? Int == current })
            else { continue }
            let types = spaces.map { $0["type"] as? Int ?? 0 }
            result[identifier] = CurrentSpace(space: current, index: index,
                                              isFullScreen: types[index] == fullScreenType, types: types)
        }
        return result
    }
}

extension NSScreen {
    /// The UUID macOS uses for this display in its Spaces configuration.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
