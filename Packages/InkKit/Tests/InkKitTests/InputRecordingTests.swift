import CoreGraphics
import Foundation
@testable import InkKit
import Testing

@MainActor
@Suite("Recorded Pencil input")
struct InputRecordingTests {
    private func sample(_ x: Double, _ y: Double, force: Double = 0.5, t: Double, pending: Bool = false)
        -> InkInputRecording.Sample {
        InkInputRecording.Sample(x: x, y: y, force: force, altitude: 1.2, azimuth: -0.7, time: t, pending: pending)
    }

    private func recordedStroke(viewScale: Double = 1) -> InkInputRecording.RecordedStroke {
        var stroke = InkInputRecording.RecordedStroke(
            tool: "pen", color: [0, 0, 0, 1],
            style: InkInputRecording.Style(width: 4, minWidthRatio: 0.25, pressureGamma: 0.6, opacity: 1,
                                           tiltEnabled: true),
            viewScale: viewScale
        )
        stroke.events = [
            InkInputRecording.Event(samples: [sample(10, 10, t: 0, pending: true), sample(12, 10, t: 0.004)],
                                    predicted: [sample(14, 10, t: 0.008)]),
            // The second sample is 0.1 pt from the first: the canvas only takes its pressure.
            InkInputRecording.Event(samples: [sample(20, 12, t: 0.008), sample(20.1, 12, force: 0.9, t: 0.012)]),
            InkInputRecording.Event(updates: [InkInputRecording.Update(sample: 0, force: 0.8, altitude: 1.0,
                                                                       azimuth: -0.5, final: true)]),
            InkInputRecording.Event(samples: [sample(30, 15, t: 0.016), sample(40, 15, t: 0.02)])
        ]
        return stroke
    }

    @Test func roundTripsThroughJSON() throws {
        var recording = InkInputRecording(source: .pencil, device: "iPad16,6", pageSize: .a4)
        recording.strokes = [recordedStroke()]
        let decoded = try InkInputRecording.decode(recording.encoded())
        #expect(decoded == recording)
        #expect(decoded.version == InkInputRecording.formatVersion)
    }

    @Test func samplesAreCompactArrays() throws {
        let data = try JSONEncoder().encode(sample(1.23456, 2, force: 0.5, t: 0.1, pending: true))
        #expect(String(bytes: data, encoding: .utf8) == "[1.235,2,0.5,1.2,-0.7,0.1,1]")
    }

    @Test func committedStrokeDropsNearDuplicatesAndAppliesUpdates() {
        let stroke = recordedStroke(viewScale: 1).committedStroke()
        #expect(stroke.points.map(\.location.x) == [10, 12, 20, 30, 40])
        #expect(stroke.points[2].force == 0.9) // the near-duplicate's pressure
        #expect(stroke.points[0].force == 0.8) // the refined estimate
        #expect(stroke.points[0].azimuth == -0.5)
    }

    @Test func spacingFollowsTheRecordedZoom() {
        // At 4× the 0.1 pt step is 0.4 view points, above the 0.3 pt cut-off, so it's kept.
        #expect(recordedStroke(viewScale: 4).committedStroke().points.count == 6)
    }

    @Test func replayMatchesTheCommittedStroke() {
        let recorded = recordedStroke()
        let replayer = InputReplayer(viewSize: CGSize(width: 512, height: 512), transform: ViewTransform())
        var events = 0
        let replayed = replayer.replay(recorded, transform: ViewTransform()) { _ in events += 1 }
        #expect(events == recorded.events.count)
        let expected = recorded.committedStroke()
        #expect(replayed.points.map(\.location) == expected.points.map(\.location))
        #expect(replayed.points.map(\.force) == expected.points.map(\.force))
        #expect(replayer.liveView.tileMemory == 0) // tiles are freed once the stroke is done
    }

    @Test func recorderCapturesEventsAndUpdatesByRawSample() throws {
        let recorder = InputRecorder()
        let stroke = recordedStroke().makeStroke()
        recorder.begin(stroke, viewScale: 2, pageSize: .letter)
        let p = { (x: CGFloat, t: TimeInterval) in
            StrokePoint(location: CGPoint(x: x, y: 5), force: 0.4, altitude: 1, azimuth: 0, timestamp: t)
        }
        recorder.sample(p(1, 100), strokeID: stroke.id, estimationKey: 7)
        recorder.sample(p(2, 100.004), strokeID: stroke.id, estimationKey: nil)
        recorder.endEvent(strokeID: stroke.id, predicted: [p(3, 100.008)])
        recorder.update(estimationKey: 7, force: 0.6, altitude: 1.1, azimuth: 0.1, final: true)
        recorder.update(estimationKey: 7, force: 0.9, altitude: 1.1, azimuth: 0.1, final: true) // already final

        let recorded = try #require(recorder.recording.strokes.first)
        #expect(recorder.recording.pageSize == .letter)
        #expect(recorded.viewScale == 2)
        #expect(recorded.events.count == 2)
        #expect(recorded.events[0].samples?.map { ($0.time * 1000).rounded() } == [0, 4])
        #expect(recorded.events[0].samples?.map(\.pending) == [true, false])
        #expect(recorded.events[0].predicted?.count == 1)
        #expect(recorded.events[1].updates == [InkInputRecording.Update(sample: 0, force: 0.6, altitude: 1.1,
                                                                        azimuth: 0.1, final: true)])
    }
}
