import SwiftUI
import AppKit

/// Own the label colors instead of inheriting NSButton's accent-colored text.
/// SwiftUI Button still supplies keyboard activation and accessibility semantics.
struct MonochromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.black.opacity(configuration.isPressed ? 0.78 : 1),
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// NSSlider retains native dragging, arrow keys, focus, and VoiceOver. Only its
/// bar drawing is customized, since macOS may ignore SwiftUI Slider's tint.
struct WaveformPlaybackSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let peaks: [Float]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = WaveformSlider()
        slider.cell = WaveformSliderCell()
        slider.sliderType = .linear
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("录音播放进度")
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = min(range.upperBound, max(range.lowerBound, value))
        slider.isEnabled = isEnabled
        slider.setAccessibilityValueDescription("\(Int(slider.doubleValue)) 秒，共 \(Int(range.upperBound)) 秒")
        (slider.cell as? WaveformSliderCell)?.peaks = peaks
        slider.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ slider: NSSlider) { value.wrappedValue = slider.doubleValue }
    }
}

private final class WaveformSlider: NSSlider {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 16) }
}

private final class WaveformSliderCell: NSSliderCell {
    var peaks: [Float] = []
    override func barRect(flipped: Bool) -> NSRect {
        guard let view = controlView else { return super.barRect(flipped: flipped) }
        return view.bounds.insetBy(dx: 3, dy: 3)
    }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let fraction = max(0, min(1, (doubleValue - minValue) / max(0.001, maxValue - minValue)))
        let bars = max(1, Int(rect.width / 4))
        let step = rect.width / Double(bars)
        for index in 0..<bars {
            let lower = index * peaks.count / bars
            let upper = min(peaks.count, max(lower + 1, (index + 1) * peaks.count / bars))
            let peak = lower < upper ? peaks[lower..<upper].max() ?? 0 : 0
            let height = max(1.5, CGFloat(sqrt(max(0, peak))) * rect.height)
            let bar = NSRect(x: rect.minX + Double(index) * step, y: rect.midY - height / 2,
                             width: max(1, step - 2), height: height)
            let played = Double(index) / Double(bars) < fraction
            (played ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.18)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
    override func drawKnob(_ knobRect: NSRect) {
        let bar = barRect(flipped: controlView?.isFlipped ?? false)
        let fraction = max(0, min(1, (doubleValue - minValue) / max(0.001, maxValue - minValue)))
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: bar.minX + bar.width * fraction - 1, y: bar.minY,
                                       width: 2, height: bar.height), xRadius: 1, yRadius: 1).fill()
    }
}
