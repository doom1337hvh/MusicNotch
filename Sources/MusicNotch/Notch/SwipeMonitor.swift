import AppKit
import CoreGraphics
import OSLog

/// Reports when a horizontal swipe between desktops starts and ends, so the notch can hide
/// for the whole transition. macOS only shares the Dock's gesture events with apps that
/// have the Input Monitoring permission, so this is opt-in ("Hide while swiping"). The tap
/// asks for nothing but Dock gestures, so it costs nothing between swipes.
@MainActor
final class SwipeMonitor {
    var onSwipeBegan: (() -> Void)?
    /// Called on release with the way the desktop will move, or nil if the swipe springs back.
    var onSwipeEnded: ((SpaceObserver.Direction?) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicNotch", category: "swipe")

    // Private event type and fields the Dock's swipe gestures use.
    private static let dockGestureType: UInt32 = 30
    private static let hidTypeField = CGEventField(rawValue: 110)!
    private static let motionField = CGEventField(rawValue: 123)!
    private static let phaseField = CGEventField(rawValue: 132)!
    /// How far the swipe went, about -1...1; negative is towards the desktop on the left.
    private static let progressField = CGEventField(rawValue: 124)!
    private static let velocityField = CGEventField(rawValue: 129)!
    private static let dockSwipeHIDType: Int64 = 23
    private static let horizontalMotion: Int64 = 1
    private static let phaseBegan: Int64 = 1
    private static let phaseEnded: Int64 = 4
    private static let phaseCancelled: Int64 = 8

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time; afterwards the user has to allow it in System Settings.
    static func requestPermission() { _ = CGRequestListenEventAccess() }

    /// Starts listening if allowed. Returns whether it's listening.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasPermission else {
            Self.logger.notice("Not listening for swipes: Input Monitoring isn't allowed")
            return false
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << Self.dockGestureType,
            callback: { _, type, event, context in
                if let context {
                    let monitor = Unmanaged<SwipeMonitor>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            Self.logger.error("Couldn't create the swipe event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        Self.logger.notice("Listening for swipes")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type.rawValue == Self.dockGestureType else { return }
        let hidType = event.getIntegerValueField(Self.hidTypeField)
        let motion = event.getIntegerValueField(Self.motionField)
        let phase = event.getIntegerValueField(Self.phaseField)
        Self.logger.debug("dock gesture hid=\(hidType) motion=\(motion) phase=\(phase)")
        // Vertical Dock swipes are Mission Control and App Exposé; leave those alone.
        guard hidType == Self.dockSwipeHIDType, motion == Self.horizontalMotion else { return }
        switch phase {
        case Self.phaseBegan:
            onSwipeBegan?()
        case Self.phaseEnded:
            // macOS only reports the switch once the desktop has settled, so work out now
            // whether the Dock will finish it: it does if the swipe went far enough or was
            // flicked that way. Err towards "finishes": the cost of a wrong guess is a slide
            // from the wrong side, which is less jarring than a fade instead of a slide.
            let progress = event.getDoubleValueField(Self.progressField)
            let velocity = event.getDoubleValueField(Self.velocityField)
            let completes = abs(progress) >= 0.3
                || (abs(velocity) >= 0.5 && (velocity > 0) == (progress > 0))
            Self.logger.debug("""
                swipe released: progress=\(progress, format: .fixed(precision: 3), privacy: .public) \
                velocity=\(velocity, format: .fixed(precision: 2), privacy: .public) \
                completes=\(completes, privacy: .public)
                """)
            onSwipeEnded?(completes ? (progress > 0 ? .forward : .backward) : nil)
        case Self.phaseCancelled:
            onSwipeEnded?(nil)
        default:
            break
        }
    }
}
