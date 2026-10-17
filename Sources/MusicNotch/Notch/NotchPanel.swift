import AppKit
import SwiftUI

/// A borderless panel that sits over the menu bar and never takes focus.
final class NotchPanel: NSPanel {
    /// A pinned panel joins every desktop and is added to `NotchSpace`; otherwise it lives on
    /// one desktop at a time and is moved to the active one after a switch.
    init(frame: CGRect, pinned: Bool) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = pinned
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Allow the frame to overlap the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the notch's SwiftUI content: buttons work on the first click, and
/// right-click shows the app menu.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var contextMenu: (@MainActor () -> NSMenu)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenu?() else { return super.rightMouseDown(with: event) }
        // Open below the panel: when pinned it sits above every other window, menus included.
        let x = convert(event.locationInWindow, from: nil).x
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: isFlipped ? bounds.maxY : bounds.minY), in: self)
    }
}

/// An invisible target over the camera housing ("Only open from the camera"). While the
/// notch is closed its panel ignores the pointer, so reaching for menu bar items beside the
/// notch never opens it; this window, sitting under the panel, catches hovers and clicks on
/// the camera area instead. It's drawn black so it receives them, but it's kept a little
/// inside the housing, which has no screen pixels, so it can't be seen.
final class NotchHotspot: NSPanel {
    var onHover: (@MainActor (Bool) -> Void)?
    var onClick: (@MainActor () -> Void)?
    var contextMenu: (@MainActor () -> NSMenu)?

    init(frame: CGRect, pinned: Bool) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = pinned
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = HotspotView(owner: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    private final class HotspotView: NSView {
        private weak var owner: NotchHotspot?
        private var trackingArea: NSTrackingArea?

        init(owner: NotchHotspot) {
            self.owner = owner
            super.init(frame: .zero)
            // Rounded at the bottom like the housing, so no corner pokes out of it.
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.cornerRadius = 8
            layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { owner?.onHover?(true) }
        override func mouseExited(with event: NSEvent) { owner?.onHover?(false) }
        override func mouseDown(with event: NSEvent) { owner?.onClick?() }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = owner?.contextMenu?() else { return super.rightMouseDown(with: event) }
            menu.popUp(positioning: nil, at: NSPoint(x: convert(event.locationInWindow, from: nil).x, y: 0), in: self)
        }
    }
}
