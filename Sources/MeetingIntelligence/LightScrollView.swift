import SwiftUI
import AppKit

/// Native scrolling and hit targets, with a quieter overlay indicator.
struct LightScrollView<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            content().background(ScrollAppearanceProbe().frame(width: 0, height: 0))
        }
    }
}

private struct ScrollAppearanceProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.scheduleAppearance() }
    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleAppearance() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleAppearance() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func scheduleAppearance() {
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView else { return }
                if !(scroll.verticalScroller is QuietScroller) {
                    let scroller = QuietScroller()
                    scroller.controlSize = .small
                    scroll.verticalScroller = scroller
                }
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
            }
        }
    }
}

private final class QuietScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let visibleKnob = NSRect(x: knob.midX - 2, y: knob.minY + 1, width: 4, height: max(0, knob.height - 2))
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: visibleKnob, xRadius: 2, yRadius: 2).fill()
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}
