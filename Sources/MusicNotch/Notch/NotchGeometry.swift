import AppKit

/// Where the notch is on a screen, and how big the collapsed and expanded panels are.
/// Screens without a notch get a pill of menu-bar height at the top center.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var hasNotch: Bool
    /// The camera housing's width; zero on screens without a notch.
    var notchWidth: CGFloat
    /// The notch height, or the menu bar height on screens without a notch.
    var height: CGFloat

    init(screen: NSScreen) {
        screenFrame = screen.frame
        let topInset = screen.safeAreaInsets.top
        hasNotch = topInset > 0
        if hasNotch {
            height = topInset
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notchWidth = screen.frame.width - left.width - right.width
            } else {
                notchWidth = 180
            }
        } else {
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            height = menuBarHeight > 0 ? menuBarHeight : 24
            notchWidth = 0
        }
    }

    /// Space beside the notch for the artwork (left) and equalizer (right).
    var wingWidth: CGFloat { height + 8 }

    var collapsedSize: CGSize {
        CGSize(width: (hasNotch ? notchWidth : 8) + 2 * wingWidth, height: height)
    }

    /// Room for a skip button on each side when the notch widens on hover (Minimal style).
    var peekButtonWidth: CGFloat { 34 }

    var peekSize: CGSize {
        CGSize(width: collapsedSize.width + 2 * peekButtonWidth, height: height)
    }

    /// The brief banner shown when the track changes. Keep in sync with `TrackPeekView`.
    var trackPeekSize: CGSize {
        let content: CGFloat = 8 + 36 + 12
        return CGSize(width: max(collapsedSize.width + 40, 300), height: height + content)
    }

    /// Keep in sync with the paddings and row heights in `CompactView`. Shuffle and repeat
    /// add two buttons to its one row, so the panel widens to leave the title its room.
    func compactSize(showsProgress: Bool, showsModes: Bool = false, sourceCount: Int = 0) -> CGSize {
        let content: CGFloat = 10 + 40 + (showsProgress ? 8 + 3 : 0) + 12
        let modeButtons: CGFloat = showsModes ? 2 * 26 : 0
        let width = max(collapsedSize.width + 40, 330 + modeButtons, widthForSourceIcons(sourceCount))
        return CGSize(width: width, height: height + content)
    }

    /// Keep in sync with the paddings and row heights in `ExpandedView`.
    func expandedSize(showsProgress: Bool, sourceCount: Int = 0) -> CGSize {
        let content: CGFloat = 12 + 56 + 14 + (showsProgress ? 18 + 14 : 0) + 30 + 16
        let width = max(collapsedSize.width + 40, 400, widthForSourceIcons(sourceCount))
        return CGSize(width: width, height: height + content)
    }

    // The source icons sit in the top band of an open panel, split across both sides of
    // the camera housing (see `TopBand`).
    static let sourceIconStep: CGFloat = 22  // 16 pt icon + 6 pt spacing
    static let sourceIconInset: CGFloat = 30  // rounded top corner plus padding

    /// How many source icons fit on each side of the camera housing in a panel this wide.
    func sourceIconsPerSide(panelWidth: CGFloat) -> Int {
        let room = (panelWidth - (hasNotch ? notchWidth : 0)) / 2 - Self.sourceIconInset
        return max(1, Int((room + 6) / Self.sourceIconStep))
    }

    /// The panel width that fits `count` source icons, half on each side.
    private func widthForSourceIcons(_ count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        let perSide = CGFloat((count + 1) / 2)
        let side = perSide * Self.sourceIconStep - 6 + Self.sourceIconInset
        return (hasNotch ? notchWidth : 0) + 2 * side
    }

    /// A window frame of `size`, hanging from the top center of the screen.
    func frame(for size: CGSize) -> CGRect {
        CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}
