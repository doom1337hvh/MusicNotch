import AppKit
import QuartzCore
import SwiftUI

/// Four bouncing bars that become a pause icon while paused. They're Core Animation layer
/// animations, which the window server runs, so the app itself does no per-frame work.
/// Capped at 30 fps.
struct EqualizerView: NSViewRepresentable {
    var isPlaying: Bool
    var animated: Bool

    func makeNSView(context: Context) -> EqualizerBarsView { EqualizerBarsView() }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.update(isPlaying: isPlaying, animated: animated)
    }
}

/// While playing the bars stand side by side; paused, they slide together in pairs into a
/// pause icon. Each change is a single short transition.
final class EqualizerBarsView: NSView {
    private static let durations: [CFTimeInterval] = [0.47, 0.61, 0.39, 0.53]
    /// Heights while playing without the animation.
    private static let restingScales: [CGFloat] = [0.55, 1, 0.7, 0.85]
    /// Where each bar's bounce starts (see `startBouncing`), so it picks up seamlessly from
    /// the transition: 0.3 at its start, 0.65 a quarter or three quarters through, 1 halfway.
    private static let bounceStartScales: [CGFloat] = [0.3, 0.65, 1, 0.65]
    private static let morphDuration: CFTimeInterval = 0.3

    private let bars: [CALayer]
    private var mode: (isPlaying: Bool, animated: Bool)?
    /// Bumped on every change, so a finished transition only starts the bounce it was for.
    private var generation = 0

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyShapes()
        CATransaction.commit()
    }

    func update(isPlaying: Bool, animated: Bool) {
        if let mode, mode == (isPlaying, animated) { return }
        // Play and pause transition; the first state, and a change while off screen, don't.
        let transitions = mode.map { $0.isPlaying != isPlaying } == true && window != nil
        mode = (isPlaying, animated)
        generation += 1
        let generation = generation

        // Carry on from wherever each bar is right now, mid-bounce or mid-transition.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            if let current = bar.presentation() {
                bar.bounds = current.bounds
                bar.position = current.position
                bar.cornerRadius = current.cornerRadius
                bar.transform = current.transform
            }
            bar.removeAllAnimations()
        }
        CATransaction.commit()

        CATransaction.begin()
        if transitions {
            CATransaction.setAnimationDuration(Self.morphDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.startBouncing(generation: generation) }
        }
        applyShapes()
        CATransaction.commit()
    }

    /// Puts each bar where the current mode has it.
    private func applyShapes() {
        let paused = mode?.isPlaying == false
        let bouncing = mode.map { $0.isPlaying && $0.animated } == true
        for (index, bar) in bars.enumerated() {
            let shape = shape(forBar: index, paused: paused)
            bar.bounds = CGRect(origin: .zero, size: shape.size)
            bar.position = shape.center
            bar.cornerRadius = shape.cornerRadius
            let scale = paused ? 1 : bouncing ? Self.bounceStartScales[index] : Self.restingScales[index]
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
    }

    /// Side by side as the equalizer, or two by two as the bars of a pause icon.
    private func shape(forBar index: Int, paused: Bool) -> (size: CGSize, center: CGPoint, cornerRadius: CGFloat) {
        if paused {
            let width = bounds.width * 0.28
            let gap = bounds.width * 0.2
            let side: CGFloat = index < bars.count / 2 ? -1 : 1
            return (CGSize(width: width, height: bounds.height * 0.85),
                    CGPoint(x: bounds.midX + side * (gap + width) / 2, y: bounds.midY), width * 0.3)
        }
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
        return (CGSize(width: width, height: bounds.height),
                CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: bounds.midY), width / 2)
    }

    /// Starts the bounce once the bars are in place, if they're still meant to bounce.
    private func startBouncing(generation: Int) {
        guard generation == self.generation, let mode, mode.isPlaying, mode.animated else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
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
