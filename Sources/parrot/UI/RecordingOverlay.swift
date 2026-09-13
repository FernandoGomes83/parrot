import AppKit
import SwiftUI

/// Borderless, click-through audio reactor near the bottom of the active screen.
/// Driven by the daemon's hotkey + transcription lifecycle.
@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        case transcribing
    }

    private var window: NSPanel?
    private let model = OverlayModel()
    private var pendingHide: DispatchWorkItem?

    func show(_ state: State) {
        pendingHide?.cancel()
        pendingHide = nil
        ensureWindow()
        if state == .recording {
            model.resetLevels()
        }
        guard let window else { return }
        let needsAppear = !window.isVisible
        if needsAppear {
            positionAtBottomCenter(window)
            window.orderFrontRegardless()
            // Defer the state change so SwiftUI lays out in the .hidden style
            // first, then animates to the visible style on the next runloop tick.
            DispatchQueue.main.async { [model] in
                model.state = state
            }
        } else {
            model.state = state
        }
    }

    func hide() {
        model.state = .hidden
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .hidden else { return }
            self.window?.orderOut(nil)
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Push a new audio level (0…~1). Safe to call from any thread.
    nonisolated func pushLevel(_ level: Float) {
        Task { @MainActor in
            self.model.pushLevel(level)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 124, height: 124),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: RecordingReactor(model: model))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    private func positionAtBottomCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 32
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// A smoothed microphone envelope; silence falls back to a quiet core.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: RecordingOverlay.State = .hidden
    @Published var level: CGFloat = 0

    func pushLevel(_ level: Float) {
        guard state == .recording else { return }
        let shaped = CGFloat(min(1, sqrt(max(0, level - 0.002)) * 3.4))
        let smoothing: CGFloat = shaped > self.level ? 0.65 : 0.28
        self.level += (shaped - self.level) * smoothing
    }

    func resetLevels() {
        level = 0
    }
}

struct RecordingReactor: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transcribing: Bool { model.state == .transcribing }
    private var tint: Color {
        transcribing
            ? Color(red: 1, green: 0.72, blue: 0.32)
            : Color(red: 0.25, green: 0.88, blue: 1)
    }
    private var energy: CGFloat { transcribing ? 0.28 : model.level }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || model.state == .hidden)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            reactor(time: time)
        }
        .frame(width: 124, height: 124)
        .opacity(model.state == .hidden ? 0 : 1)
        .scaleEffect(reduceMotion ? 1 : (model.state == .hidden ? 0.82 : 1))
        .animation(.easeOut(duration: 0.18), value: model.state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(transcribing ? "Transcribing" : "Recording")
        .accessibilityHidden(model.state == .hidden)
    }

    private func reactor(time: TimeInterval) -> some View {
        let speed = transcribing ? 36.0 : 6.0
        let rotation = (time * speed).truncatingRemainder(dividingBy: 360)
        let counterRotation = (-time * speed * 1.4 + 35).truncatingRemainder(dividingBy: 360)
        return ZStack {
            // Dark glass keeps the fine telemetry legible over any app.
            Circle()
                .fill(Color(red: 0.025, green: 0.055, blue: 0.075).opacity(0.96))
                .frame(width: 106, height: 106)
            Circle()
                .stroke(tint.opacity(0.12), lineWidth: 1)
                .frame(width: 106, height: 106)
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.24 + energy * 0.2), .clear],
                                     center: .center, startRadius: 10, endRadius: 53))
                .frame(width: 110, height: 110)

            // The radial meter is driven by microphone amplitude, not random bars.
            ForEach(0..<48, id: \.self) { index in
                let emphasis = CGFloat(index % 4 == 0 ? 1 : 0.55)
                Capsule()
                    .fill(tint.opacity(0.35 + energy * 0.6))
                    .frame(width: index % 4 == 0 ? 2 : 1, height: 8)
                    .scaleEffect(y: reduceMotion ? 0.5 : 0.3 + energy * emphasis, anchor: .bottom)
                    .offset(y: -47)
                    .rotationEffect(.degrees(Double(index) * 7.5))
            }

            ring(diameter: 79, segments: 3, sweep: 0.22, lineWidth: 2)
                .rotationEffect(.degrees(rotation))
            ring(diameter: 67, segments: 2, sweep: 0.34, lineWidth: 1)
                .rotationEffect(.degrees(counterRotation))
                .opacity(0.55)

            Circle()
                .stroke(tint.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                .frame(width: 55, height: 55)

            // A luminous spherical core expands on voice attack and settles in silence.
            Circle()
                .fill(RadialGradient(
                    stops: [.init(color: .white, location: 0),
                            .init(color: tint.opacity(0.95), location: 0.3),
                            .init(color: tint.opacity(0.3), location: 0.7),
                            .init(color: tint.opacity(0.05), location: 1)],
                    center: .init(x: 0.42, y: 0.38), startRadius: 0, endRadius: 20))
                .overlay(Circle().stroke(tint.opacity(0.8), lineWidth: 0.8))
                .frame(width: 34, height: 34)
                .shadow(color: tint.opacity(0.5), radius: 6 + energy * 7)
                .scaleEffect(reduceMotion ? 1 : 0.88 + energy * 0.3)

            if transcribing {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 0.12, green: 0.08, blue: 0.02))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: model.level)
    }

    private func ring(diameter: CGFloat, segments: Int, sweep: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            ForEach(0..<segments, id: \.self) { index in
                Circle()
                    .trim(from: 0, to: sweep)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(Double(index) * 360 / Double(segments)))
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: tint.opacity(0.4), radius: 3)
    }
}
