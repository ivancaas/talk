import AppKit
import SwiftUI

/// Floating status pill, shown on the screen under the mouse.
/// Non-activating, click-through, so focus and the paste target never change.
/// The window exists only while visible.
@MainActor
final class HUD {
    enum Phase: Equatable {
        case loading, listening, transcribing, done(String), error(String)
    }

    final class Model: ObservableObject {
        @Published var phase: Phase = .loading
        @Published var level: Float = 0
    }

    let model = Model()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let atTop: Bool
    private static let size = NSSize(width: 360, height: 64)

    init(atTop: Bool) { self.atTop = atTop }

    func show(_ phase: Phase) {
        hideWork?.cancel()
        model.phase = phase
        if phase != .listening { model.level = 0 }
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
    }

    func setLevel(_ level: Float) {
        guard model.phase == .listening else { return }
        model.level = level
    }

    /// Flash a final state, then hide.
    func finish(_ phase: Phase, after seconds: Double) {
        show(phase)
        hide(after: seconds)
    }

    func hide(after seconds: Double = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.contentView = nil
            self?.panel = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        p.contentView = host
        return p
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame, let panel else { return }
        let x = frame.midX - Self.size.width / 2
        let y = atTop ? frame.maxY - Self.size.height - 8 : frame.minY + 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct PillView: View {
    @ObservedObject var model: HUD.Model

    var body: some View {
        HStack(spacing: 9) {
            indicator.frame(width: 40, height: 20)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(height: 36)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }

    private var label: String {
        switch model.phase {
        case .loading: "Loading model…"
        case .listening: "Listening"
        case .transcribing: "Transcribing…"
        case .done(let s), .error(let s): s
        }
    }

    private var tint: Color {
        switch model.phase {
        case .listening: .red
        case .error: .orange
        default: .primary
        }
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .loading, .transcribing: Dots(level: 0, pulsing: true)
        case .listening: Dots(level: model.level, pulsing: false)
        case .done: Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
        case .error: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
        }
    }
}

/// Five dots: they bounce with the mic level while listening, and run a soft wave while busy.
private struct Dots: View {
    var level: Float
    var pulsing: Bool
    private let base: [CGFloat] = [0.7, 0.85, 1.0, 0.85, 0.7]
    private let response: [CGFloat] = [0.5, 0.8, 1.1, 0.8, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !pulsing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let scale = pulsing
                        ? 0.75 + 0.45 * CGFloat((sin(t * 6 - Double(i) * 0.7) + 1) / 2)
                        : base[i] + CGFloat(level) * response[i]
                    Circle()
                        .frame(width: 4.5, height: 4.5)
                        .scaleEffect(scale)
                        .opacity(0.9)
                }
            }
            .animation(pulsing ? nil : .easeOut(duration: 0.08), value: level)
        }
    }
}

extension HUD {
    /// Renders every pill state to PNGs (visual check without screenshots).
    static func renderPreviews(to dir: URL) {
        let states: [(String, HUD.Phase, Float)] = [
            ("loading", .loading, 0), ("listening", .listening, 0.6), ("transcribing", .transcribing, 0),
            ("done", .done("Pasted"), 0), ("error", .error("Nothing heard"), 0),
        ]
        for (name, phase, level) in states {
            let m = Model()
            m.phase = phase
            m.level = level
            let r = ImageRenderer(content: PillView(model: m).frame(width: 260, height: 56).background(Color(white: 0.15)))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("pill-\(name).png"))
            }
        }
    }
}
