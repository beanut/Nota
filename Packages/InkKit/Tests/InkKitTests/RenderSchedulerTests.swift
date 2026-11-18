import CoreGraphics
import Foundation
@testable import InkKit
import Testing
import UIKit

/// Lets the main queue run until `done`, or fails after `timeout`.
@MainActor
private func waitUntil(timeout: TimeInterval = 10, _ done: () -> Bool) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !done() {
        guard Date() < deadline else {
            Issue.record("timed out")
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Things worker threads record, in order.
private final class Log: @unchecked Sendable { // guarded by `lock`
    private let lock = NSLock()
    private var items: [String] = []
    private var running = 0
    private(set) var maxRunning = 0

    func append(_ item: String) {
        lock.withLock { items.append(item) }
    }

    var all: [String] {
        lock.withLock { items }
    }

    func enter() {
        lock.withLock {
            running += 1
            maxRunning = max(maxRunning, running)
        }
    }

    func leave() {
        lock.withLock { running -= 1 }
    }

    var peak: Int {
        lock.withLock { maxRunning }
    }
}

/// The render scheduler (NOT-103): priority order, cancellation, coalescing, bounded concurrency and
/// batched publishing.
@MainActor
@Suite("Render scheduler", .serialized)
struct RenderSchedulerTests {
    /// A job holding its worker until `gate` is signalled.
    private func blocker(_ scheduler: RenderScheduler, gate: DispatchSemaphore,
                         priority: RenderPriority = .underPencil) -> RenderJob {
        let job = RenderJob(priority: priority, work: { _ -> Bool? in
            gate.wait()
            return true
        }, publish: { (_: Bool?) in })
        scheduler.submit(job)
        return job
    }

    @Test func jobsStartByPriorityThenRankThenSubmission() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 1, gesture: 1, lowPriority: 1), frameInterval: 0)
        let gate = DispatchSemaphore(value: 0)
        _ = blocker(scheduler, gate: gate)
        let log = Log()
        var published = 0
        struct Spec {
            let name: String
            let priority: RenderPriority
            let rank: Double
        }
        let jobs = [
            Spec(name: "background", priority: .background, rank: 0), Spec(name: "margin-2", priority: .margin, rank: 2),
            Spec(name: "visible-1", priority: .visible, rank: 1), Spec(name: "margin-1", priority: .margin, rank: 1),
            Spec(name: "pencil", priority: .underPencil, rank: 5), Spec(name: "visible-0", priority: .visible, rank: 0),
            Spec(name: "visible-1b", priority: .visible, rank: 1), Spec(name: "other", priority: .otherLevel, rank: 0)
        ]
        for spec in jobs {
            let name = spec.name
            scheduler.submit(RenderJob(priority: spec.priority, rank: spec.rank, work: { _ -> String? in
                log.append(name)
                return name
            }, publish: { (_: String?) in published += 1 }))
        }
        gate.signal()
        // Utility QoS: slow while other tests fill every core.
        try await waitUntil(timeout: 120) { published == jobs.count }
        #expect(log.all == ["pencil", "visible-0", "visible-1", "visible-1b", "margin-1", "margin-2", "other",
                            "background"])
    }

    @Test func aJobMovedUpTheQueueStartsSooner() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 1, gesture: 1, lowPriority: 1), frameInterval: 0)
        let gate = DispatchSemaphore(value: 0)
        _ = blocker(scheduler, gate: gate)
        let log = Log()
        var published = 0
        var margin: RenderJob?
        for (name, priority) in [("visible", RenderPriority.visible), ("margin", .margin)] {
            let job = RenderJob(priority: priority, work: { _ -> String? in
                log.append(name)
                return name
            }, publish: { (_: String?) in published += 1 })
            if priority == .margin {
                margin = job
            }
            scheduler.submit(job)
        }
        try scheduler.reprioritise(#require(margin), to: .underPencil, rank: 0)
        gate.signal()
        try await waitUntil { published == 2 }
        #expect(log.all == ["margin", "visible"])
    }

    @Test func aJobCancelledBeforeItStartsNeverRunsAndPublishesNil() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 1, gesture: 1, lowPriority: 1), frameInterval: 0)
        let gate = DispatchSemaphore(value: 0)
        _ = blocker(scheduler, gate: gate)
        let log = Log()
        var results: [String?] = []
        let job = RenderJob(priority: .visible, work: { _ -> String? in
            log.append("ran")
            return "pixels"
        }, publish: { (output: String?) in results.append(output) })
        scheduler.submit(job)
        job.cancel()
        // Published at once, without waiting for the worker the blocker holds.
        try await waitUntil { results.count == 1 }
        #expect(results == [nil])
        gate.signal()
        try await waitUntil { scheduler.counts == (0, 0) }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(log.all.isEmpty)
        #expect(results == [nil])
    }

    @Test func aTokenCancelledBeforeAJobStartsDropsIt() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 1, gesture: 1, lowPriority: 1), frameInterval: 0)
        let gate = DispatchSemaphore(value: 0)
        _ = blocker(scheduler, gate: gate)
        let owner = RenderCancellation()
        let token = RenderCancellation(parent: owner)
        let log = Log()
        var results: [String?] = []
        scheduler.submit(RenderJob(priority: .visible, cancellation: token, work: { _ -> String? in
            log.append("ran")
            return "pixels"
        }, publish: { (output: String?) in results.append(output) }))
        owner.cancel() // the owner went: its child token is cancelled too
        gate.signal()
        try await waitUntil { results.count == 1 }
        #expect(results == [nil])
        #expect(log.all.isEmpty)
    }

    @Test func aRunningJobSeesItsCancellationAndItsOutputIsDropped() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 2, gesture: 2, lowPriority: 1), frameInterval: 0)
        let started = DispatchSemaphore(value: 0)
        let log = Log()
        var results: [String?] = []
        let job = RenderJob(priority: .visible, work: { job -> String? in
            started.signal()
            // Strokes, checking between each, as a tile fill does.
            for _ in 0 ..< 2000 where !job.isCancelled {
                usleep(1000)
            }
            log.append(job.isCancelled ? "stopped" : "finished")
            return "stale pixels"
        }, publish: { (output: String?) in results.append(output) })
        scheduler.submit(job)
        try await waitUntil { started.wait(timeout: .now()) == .success }
        job.cancel()
        try await waitUntil { results.count == 1 }
        #expect(log.all == ["stopped"])
        #expect(results == [nil]) // it returned pixels, but they're never published
    }

    @Test func aJobCancelledAfterItsWorkIsDoneButBeforeItsBatchNeverPublishes() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 2, gesture: 2, lowPriority: 1), frameInterval: 0)
        var results: [String?] = []
        scheduler.holdsBatches = true
        let job = RenderJob(priority: .visible, work: { _ in "superseded" },
                            publish: { (output: String?) in results.append(output) })
        scheduler.submit(job)
        try await waitUntil { scheduler.counts == (0, 0) } // done, not yet published
        #expect(results.isEmpty)
        job.cancel()
        scheduler.holdsBatches = false
        try await waitUntil { results.count == 1 }
        #expect(results == [nil])
    }

    @Test func aNewerJobWithTheSameKeySupersedesOneNotStarted() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 1, gesture: 1, lowPriority: 1), frameInterval: 0)
        let gate = DispatchSemaphore(value: 0)
        _ = blocker(scheduler, gate: gate)
        let log = Log()
        var results: [String?] = []
        for name in ["old", "new"] {
            scheduler.submit(RenderJob(priority: .visible, coalescingKey: "panel", work: { _ -> String? in
                log.append(name)
                return name
            }, publish: { (output: String?) in results.append(output) }))
        }
        gate.signal()
        try await waitUntil { results.count == 2 }
        #expect(log.all == ["new"])
        #expect(results == [nil, "new"])
    }

    @Test func anOlderJobWithTheSameKeyFinishingAfterANewerOneIsDropped() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 2, gesture: 2, lowPriority: 1), frameInterval: 0)
        let slowGate = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
        var results: [String?] = []
        scheduler.submit(RenderJob(priority: .visible, coalescingKey: "mirror", work: { _ -> String? in
            started.signal()
            slowGate.wait()
            return "old"
        }, publish: { (output: String?) in results.append(output) }))
        try await waitUntil { started.wait(timeout: .now()) == .success } // running: not cancelled by the newer one
        scheduler.submit(RenderJob(priority: .visible, coalescingKey: "mirror", work: { _ in "new" },
                                   publish: { (output: String?) in results.append(output) }))
        try await waitUntil { results.count == 1 }
        #expect(results == ["new"])
        slowGate.signal()
        try await waitUntil { results.count == 2 }
        #expect(results == ["new", nil]) // stale pixels never land over fresh ones
    }

    @Test func atMostTheLimitRunsAndFewerDuringAGesture() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 4, gesture: 2, lowPriority: 1), frameInterval: 0)
        let owner = NSObject()
        scheduler.setGesture(true, for: ObjectIdentifier(owner))
        let log = Log()
        var published = 0
        func submit(_ count: Int) {
            for _ in 0 ..< count {
                scheduler.submit(RenderJob(priority: .visible, work: { _ -> Bool? in
                    log.enter()
                    usleep(20000)
                    log.leave()
                    return true
                }, publish: { (_: Bool?) in published += 1 }))
            }
        }
        submit(8)
        try await waitUntil { published == 8 }
        #expect(log.peak == 2)

        scheduler.setGesture(false, for: ObjectIdentifier(owner))
        let idle = Log()
        published = 0
        for _ in 0 ..< 12 {
            scheduler.submit(RenderJob(priority: .visible, work: { _ -> Bool? in
                idle.enter()
                usleep(20000)
                idle.leave()
                return true
            }, publish: { (_: Bool?) in published += 1 }))
        }
        try await waitUntil { published == 12 }
        #expect(idle.peak <= 4)
        #expect(idle.peak > 2)
    }

    @Test func lowPriorityJobsTakeOnlyTheirShareOfWorkers() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 4, gesture: 4, lowPriority: 1), frameInterval: 0)
        let low = Log()
        var published = 0
        for _ in 0 ..< 6 {
            scheduler.submit(RenderJob(priority: .background, work: { _ -> Bool? in
                low.enter()
                low.append("background")
                usleep(30000)
                low.leave()
                return true
            }, publish: { (_: Bool?) in published += 1 }))
        }
        // A visible job doesn't wait behind them: it starts while the first is still running.
        scheduler.submit(RenderJob(priority: .visible, work: { _ -> Bool? in
            low.append("visible")
            return true
        }, publish: { (_: Bool?) in published += 1 }))
        try await waitUntil(timeout: 120) { published == 7 }
        #expect(low.peak == 1)
        #expect(try #require(low.all.firstIndex(of: "visible")) <= 1)
    }

    @Test func jobsFinishingTogetherArePublishedInOneBatch() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 8, gesture: 8, lowPriority: 1), frameInterval: 0)
        let owner = NSObject()
        var published = 0
        var batches = 0
        var publishedAtBatch: [Int] = []
        scheduler.holdsBatches = true // as if they all finished within one frame
        for _ in 0 ..< 6 {
            scheduler.submit(RenderJob(priority: .visible, work: { _ in true }, publish: { (_: Bool?) in
                published += 1
                scheduler.afterBatch(owner) {
                    batches += 1
                    publishedAtBatch.append(published)
                }
            }))
        }
        try await waitUntil { scheduler.counts == (0, 0) }
        scheduler.holdsBatches = false
        try await waitUntil { published == 6 }
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(batches == 1)
        #expect(publishedAtBatch == [6])
    }

    @Test func batchesArePublishedAtMostOncePerFrame() async throws {
        let scheduler = RenderScheduler(limits: .init(idle: 2, gesture: 2, lowPriority: 1), frameInterval: 0.1)
        var times: [CFTimeInterval] = []
        for _ in 0 ..< 3 {
            let count = times.count
            scheduler.submit(RenderJob(priority: .visible, work: { _ in true }, publish: { (_: Bool?) in
                times.append(CACurrentMediaTime())
            }))
            try await waitUntil { times.count == count + 1 }
        }
        #expect(times[1] - times[0] >= 0.09)
        #expect(times[2] - times[1] >= 0.09)
    }

    @Test func busyIntervalsMergeOverlappingSpans() {
        var busy = BusyIntervals()
        busy.add(0 ... 10_000_000)
        busy.add(5_000_000 ... 15_000_000)
        busy.add(20_000_000 ... 21_000_000)
        busy.add(14_000_000 ... 20_500_000)
        #expect(busy.spans == [0 ... 21_000_000])
        #expect(busy.milliseconds == 21)
    }
}
