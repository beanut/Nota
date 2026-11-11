import SwiftUI

/// Samples-per-second over a sliding one-second window (timestamps on the UITouch clock).
struct RateCounter {
    private var stamps: [TimeInterval] = []

    mutating func record(_ t: TimeInterval) {
        stamps.append(t)
        trim(t)
    }

    mutating func rate(at now: TimeInterval) -> Double {
        trim(now)
        return Double(stamps.count)
    }

    private mutating func trim(_ now: TimeInterval) {
        if let first = stamps.firstIndex(where: { $0 >= now - 1 }) {
            if first > 0 { stamps.removeFirst(first) }
        } else {
            stamps.removeAll()
        }
    }
}

/// Live input values for the HUD, throttled to ~30 Hz so SwiftUI never sits on the 240 Hz input path.
@MainActor
final class PencilTelemetry: ObservableObject {
    struct Snapshot: Equatable {
        enum InputState: Equatable {
            case idle, pencilDown, simulatedPencil, hovering
            case finger(Int)

            var label: String {
                switch self {
                case .idle: return "idle"
                case .pencilDown: return "pencil ✎"
                case .simulatedPencil: return "sim pencil (fake force)"
                case .hovering: return "pencil hover"
                case .finger(let n): return "finger ×\(n)"
                }
            }
        }

        var state: InputState = .idle
        var force: CGFloat = 0
        var maxForce: CGFloat = 0
        var normalizedForce: CGFloat = 0
        var altitude: CGFloat = .pi / 2
        var azimuth: CGFloat = 0
        var zOffset: CGFloat = 0
        var samplesPerSecond: Double = 0
        var eventsPerSecond: Double = 0
        var predictedCount = 0
        var pendingEstimates = 0
        var strokeCount = 0
    }

    @Published private(set) var snapshot = Snapshot()
    private var pending: Snapshot?
    private var lastPublish: CFTimeInterval = 0
    private var flushScheduled = false
    private let interval: CFTimeInterval = 1.0 / 30

    func submit(_ s: Snapshot, immediately: Bool) {
        let now = CACurrentMediaTime()
        if immediately || now - lastPublish >= interval {
            publish(s, at: now)
            return
        }
        pending = s
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 34_000_000)
            guard let self else { return }
            self.flushScheduled = false
            if let p = self.pending { self.publish(p, at: CACurrentMediaTime()) }
        }
    }

    private func publish(_ s: Snapshot, at time: CFTimeInterval) {
        pending = nil
        lastPublish = time
        if snapshot != s { snapshot = s }
    }
}

struct PencilHUD: View {
    @ObservedObject var telemetry: PencilTelemetry

    var body: some View {
        let s = telemetry.snapshot
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                row("state", s.state.label)
                row("force", String(format: "%.3f / %.2f", s.force, s.maxForce))
                row("pressure", String(format: "%.3f", s.normalizedForce))
                ForceBar(value: s.normalizedForce)
                row("altitude", String(format: "%5.1f°", degrees(s.altitude)))
                row("azimuth", String(format: "%5.1f°", degrees(s.azimuth)))
                row("hover z", String(format: "%.3f", s.zOffset))
                row("samples/s", String(format: "%.0f", s.samplesPerSecond))
                row("events/s", String(format: "%.0f", s.eventsPerSecond))
                row("predicted", "\(s.predictedCount)")
                row("est. pending", "\(s.pendingEstimates)")
                row("strokes", "\(s.strokeCount)")
            }
            TiltCompass(altitude: s.altitude, azimuth: s.azimuth)
                .frame(width: 84, height: 84)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.6)).frame(width: 92, alignment: .leading)
            Text(value)
        }
    }

    private func degrees(_ r: CGFloat) -> Double { Double(r) * 180 / .pi }
}

private struct ForceBar: View {
    let value: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(.green).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(width: 180, height: 6)
        .padding(.vertical, 2)
    }
}

/// Top-down view of the Pencil: the line points along azimuth, its length is the barrel's
/// projection (cos altitude), so upright = dot, flat = full radius.
private struct TiltCompass: View {
    let altitude: CGFloat
    let azimuth: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 2
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(.white.opacity(0.35)), lineWidth: 1)
            let len = r * cos(altitude)
            let end = CGPoint(x: c.x + cos(azimuth) * len, y: c.y + sin(azimuth) * len)
            var line = Path()
            line.move(to: c)
            line.addLine(to: end)
            ctx.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.white))
        }
    }
}
