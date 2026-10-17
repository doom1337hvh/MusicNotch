import AppKit
import QuartzCore
import SwiftUI

/// Four bouncing bars. They're Core Animation layer animations, which the window
/// server runs, so the app itself does no per-frame work. Capped at 30 fps.
struct EqualizerView: NSViewRepresentable {
    var isPlaying: Bool
    var animated: Bool

    func makeNSView(context: Context) -> EqualizerBarsView { EqualizerBarsView() }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.update(isPlaying: isPlaying, animated: animated)
    }
}

final class EqualizerBarsView: NSView {
    private static let durations: [CFTimeInterval] = [0.47, 0.61, 0.39, 0.53]
    private static let restingScales: [CGFloat] = [0.55, 1, 0.7, 0.85]
    private static let pausedScale: CGFloat = 0.25

    private let bars: [CALayer]
    private var mode: (isPlaying: Bool, animated: Bool)?

    init() {
        bars = Self.durations.map { _ in
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            return bar
        }
        super.init(frame: .zero)
        wantsLayer = true
        bars.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: bounds.midY)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
    }

    func update(isPlaying: Bool, animated: Bool) {
        if let mode, mode == (isPlaying, animated) { return }
        mode = (isPlaying, animated)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            let scale = isPlaying ? Self.restingScales[index] : Self.pausedScale
            bar.transform = CATransform3DMakeScale(1, scale, 1)
            guard isPlaying && animated else { continue }
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.3
            bounce.toValue = 1.0
            bounce.duration = Self.durations[index]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.timeOffset = Self.durations[index] * Double(index) / 2
            bounce.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            bar.add(bounce, forKey: "bounce")
        }
        CATransaction.commit()
    }
}
