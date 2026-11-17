import Foundation
import QuartzCore

/// How soon a render job's pixels are wanted (NOT-103). Jobs start in this order, then by their rank
/// (centre-out for tiles), then first come first served.
enum RenderPriority: Int, Comparable, Sendable, CaseIterable {
    /// Tiles under the Pencil, and finished strokes being drawn into the tiles they reach.
    case underPencil
    /// Tiles in view at the level the view shows, and the zoom window's panel.
    case visible
    /// The ring of tiles around the view, so a pan finds them cached; the presentation mirror.
    case margin
    /// Tiles at a level the view isn't showing (the page's raster, kept at the resting level).
    case otherLevel
    /// Anything nobody is waiting on: geometry warm-up, page thumbnails.
    case background

    static func < (lhs: RenderPriority, rhs: RenderPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The quality of service a job of this priority runs at.
    var qos: DispatchQoS.QoSClass {
        switch self {
        case .underPencil, .visible: .userInteractive
        case .margin: .userInitiated
        case .otherLevel, .background: .utility
        }
    }

    /// True for the priorities that may only take a few workers, so they never hold up the rest.
    var isLow: Bool {
        self >= .otherLevel
    }
}

/// Lets a render job stop once what it draws is no longer wanted. A token can hang under another (an
/// owner's lifetime), and is cancelled when that one is.
final class RenderCancellation: @unchecked Sendable { // guarded by `lock`
    private let lock = NSLock()
    private var cancelled = false
    private let parent: RenderCancellation?

    init(parent: RenderCancellation? = nil) {
        self.parent = parent
    }

    var isCancelled: Bool {
        lock.withLock { cancelled } || (parent?.isCancelled ?? false)
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

/// One piece of render work: a tile, a finished stroke drawn into the tiles it reaches, the zoom panel's
/// image, a page thumbnail. Its `work` runs on a worker thread and may check `isCancelled` between
/// strokes; its `publish` runs on the main thread, in a batch with the other jobs that finished in the
/// same frame, with the work's output, or with nil when the job was cancelled (before it started, while
/// it ran, or after, before its batch was published) or its work gave nothing. `publish` runs exactly once.
final class RenderJob: @unchecked Sendable { // `lock` guards `cancelled`; the scheduler's lock the rest
    /// Set by the scheduler under its lock.
    fileprivate(set) var priority: RenderPriority
    fileprivate(set) var rank: Double
    fileprivate var sequence: UInt64 = 0
    fileprivate weak var scheduler: RenderScheduler?
    fileprivate var isQueued = false
    /// A newer job with the same key supersedes this one: cancels it if it hasn't started, and drops its output if
    /// the newer one publishes first.
    let coalescingKey: AnyHashable?
    private let token: RenderCancellation?
    private let lock = NSLock()
    private var cancelled = false
    private var execute: ((RenderJob) -> Void)?
    private var deliver: ((RenderJob) -> Void)?
    /// The work's output: written by the worker before it reports back, read on the main thread after.
    private var output: Any?

    init<Output>(priority: RenderPriority, rank: Double = 0, coalescingKey: AnyHashable? = nil,
                 cancellation: RenderCancellation? = nil,
                 work: @escaping @Sendable (RenderJob) -> Output?,
                 publish: @escaping @MainActor (Output?) -> Void) {
        self.priority = priority
        self.rank = rank
        self.coalescingKey = coalescingKey
        token = cancellation
        execute = { job in
            job.output = work(job)
        }
        deliver = { job in
            let result = job.isCancelled ? nil : job.output as? Output
            MainActor.assumeIsolated { publish(result) }
        }
    }

    /// True once the job is cancelled, or the token it was given is.
    var isCancelled: Bool {
        lock.withLock { cancelled } || (token?.isCancelled ?? false)
    }

    /// Drops the job: if it hasn't started it never will, if it's running its output is thrown away. Its
    /// `publish` gets nil.
    func cancel() {
        lock.withLock { cancelled = true }
        scheduler?.dequeue(self)
    }

    /// Marks the job cancelled without touching the scheduler (it's publishing it).
    fileprivate func supersede() {
        lock.withLock { cancelled = true }
    }

    fileprivate func run() {
        execute?(self)
        execute = nil
    }

    /// Main thread.
    fileprivate func publish() {
        deliver?(self)
        deliver = nil
        output = nil
    }

    /// Orders jobs: priority, then rank, then submission.
    fileprivate func precedes(_ other: RenderJob) -> Bool {
        (priority, rank, sequence) < (other.priority, other.rank, other.sequence)
    }
}

/// The one place render work runs (NOT-103): canvas tiles, finished strokes, the zoom panel, the
/// presentation mirror, page thumbnails, geometry warm-up and page rasters. Jobs wait in a queue ordered
/// by priority (`RenderPriority`, then rank, then submission) and start on a bounded number of workers:
///
/// - **Bounded.** At most `limits.idle` jobs run at once (one core short of all of them, for the main
///   thread), and while any view is in a gesture `limits.gesture` (leaving at least two performance cores
///   to the main thread and the render server). Low-priority jobs (`otherLevel`, `background`) take at most
///   `limits.lowPriority` workers between them, so they never hold the rest up for long.
/// - **Cancellable.** A cancelled job never starts; a running one checks `isCancelled` between strokes
///   and its output is dropped. A job with a coalescing key supersedes the older ones with that key: one
///   not started is cancelled, one running publishes only if nothing newer has (never stale over fresh).
/// - **Published in batches.** Finished jobs are published on the main thread together, at most once per
///   `frameInterval`; owners hear once per batch (`afterBatch`), so they lay out once for many tiles.
final class RenderScheduler: @unchecked Sendable { // every stored property is guarded by `lock`, bar `batchActions`
    static let shared = RenderScheduler()

    struct Limits: Equatable, Sendable {
        /// Jobs running at once when no view is in a gesture.
        var idle: Int
        /// Jobs running at once while a view is in a gesture.
        var gesture: Int
        /// `otherLevel` and `background` jobs running at once, among the others.
        var lowPriority: Int

        /// For this device: every core but one, and in a gesture two performance cores fewer than it has.
        static var device: Limits {
            let total = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let performance = sysctl("hw.perflevel0.logicalcpu") ?? total
            return Limits(idle: max(1, total - 1), gesture: max(1, min(total, performance) - 2), lowPriority: 2)
        }

        private static func sysctl(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
            return Int(value)
        }
    }

    let limits: Limits
    /// The shortest time between two published batches: a frame at 120 Hz.
    let frameInterval: CFTimeInterval

    private let lock = NSLock()
    private var queue: [RenderJob] = []
    private var running = 0
    private var runningLow = 0
    private var nextSequence: UInt64 = 0
    private var latest: [AnyHashable: RenderJob] = [:]
    /// The newest job published for each coalescing key (sequence numbers only ever go up, so a key reused
    /// by a new owner never drops its jobs).
    private var published: [AnyHashable: UInt64] = [:]
    private var gestures = Set<ObjectIdentifier>()
    private var finished: [RenderJob] = []
    private var flushScheduled = false
    private var lastFlush: CFTimeInterval = 0
    private var holding = false
    /// What owners asked to run once the batch being published is done. Main thread only.
    private var batchActions: [ObjectIdentifier: () -> Void] = [:]
    private var batchOrder: [ObjectIdentifier] = []

    init(limits: Limits = .device, frameInterval: CFTimeInterval = 1.0 / 120) {
        self.limits = limits
        self.frameInterval = frameInterval
    }

    // MARK: Submitting

    func submit(_ job: RenderJob) {
        submit([job])
    }

    /// Queues `jobs` (in this order among equals) and starts what the limits allow.
    func submit(_ jobs: [RenderJob]) {
        var superseded: [RenderJob] = []
        lock.withLock {
            for job in jobs {
                job.scheduler = self
                job.sequence = nextSequence
                nextSequence &+= 1
                if let key = job.coalescingKey {
                    if let old = latest[key], old !== job, old.isQueued {
                        superseded.append(old)
                    }
                    latest[key] = job
                }
                job.isQueued = true
                queue.append(job)
            }
        }
        for old in superseded {
            old.cancel()
        }
        pump()
    }

    /// True once `job` has left the queue: started, finished or dropped.
    func hasStarted(_ job: RenderJob) -> Bool {
        lock.withLock { !job.isQueued }
    }

    /// Moves a queued job up or down the queue (a margin tile that came into view). No effect once started.
    func reprioritise(_ job: RenderJob, to priority: RenderPriority, rank: Double) {
        lock.withLock {
            guard job.isQueued else { return }
            job.priority = priority
            job.rank = rank
        }
    }

    /// `owner` is in a gesture (or no longer): while any is, fewer jobs run at once.
    func setGesture(_ active: Bool, for owner: ObjectIdentifier) {
        let changed = lock.withLock {
            active ? gestures.insert(owner).inserted : gestures.remove(owner) != nil
        }
        if changed, !active {
            pump()
        }
    }

    /// Jobs waiting to start, and running (for tests and the HUD).
    var counts: (queued: Int, running: Int) {
        lock.withLock { (queue.count, running) }
    }

    /// While true, finished jobs wait unpublished (tests: a job done but not yet published).
    var holdsBatches: Bool {
        get { lock.withLock { holding } }
        set {
            lock.withLock {
                holding = newValue
                if !newValue, !finished.isEmpty {
                    scheduleFlush()
                }
            }
        }
    }

    private var limit: Int {
        gestures.isEmpty ? limits.idle : limits.gesture
    }

    // MARK: Running

    /// A cancelled job leaves the queue at once, to be published (with nil) in the next batch.
    fileprivate func dequeue(_ job: RenderJob) {
        let removed = lock.withLock {
            guard job.isQueued, let i = queue.firstIndex(where: { $0 === job }) else { return false }
            queue.remove(at: i)
            job.isQueued = false
            finished.append(job)
            scheduleFlush()
            return true
        }
        if removed {
            pump()
        }
    }

    /// Starts the most urgent queued jobs the limits allow; cancelled ones are published unstarted.
    private func pump() {
        var start: [RenderJob] = []
        lock.withLock {
            while running < limit, let i = nextIndex() {
                let job = queue.remove(at: i)
                job.isQueued = false
                if job.isCancelled {
                    finished.append(job)
                    scheduleFlush()
                    continue
                }
                running += 1
                if job.priority.isLow {
                    runningLow += 1
                }
                start.append(job)
            }
        }
        for job in start {
            let low = job.priority.isLow
            DispatchQueue.global(qos: job.priority.qos).async { [self] in
                if !job.isCancelled {
                    job.run()
                }
                lock.withLock {
                    running -= 1
                    if low {
                        runningLow -= 1
                    }
                    finished.append(job)
                    scheduleFlush()
                }
                pump()
            }
        }
    }

    /// The queue position of the job to start next, if any may start. Under `lock`.
    private func nextIndex() -> Int? {
        let lowAllowed = runningLow < limits.lowPriority
        var best: Int?
        for (i, job) in queue.enumerated() where lowAllowed || !job.priority.isLow || job.isCancelled {
            if let b = best, !job.precedes(queue[b]) {
                continue
            }
            best = i
        }
        return best
    }

    // MARK: Publishing

    /// Publishes the finished jobs on the main thread, no sooner than a frame after the last batch. Under `lock`.
    private func scheduleFlush() {
        guard !flushScheduled, !holding else { return }
        flushScheduled = true
        let wait = max(0, lastFlush + frameInterval - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            MainActor.assumeIsolated { flush() }
        }
    }

    @MainActor
    private func flush() {
        let batch: [RenderJob] = lock.withLock {
            flushScheduled = false
            lastFlush = CACurrentMediaTime()
            let batch = finished.sorted { $0.sequence < $1.sequence }
            finished = []
            for job in batch {
                guard let key = job.coalescingKey else { continue }
                if latest[key] === job {
                    latest[key] = nil
                }
                // An older job with this key that finishes after a newer one published is out of date.
                if let newer = published[key], newer > job.sequence {
                    job.supersede()
                } else if !job.isCancelled {
                    published[key] = job.sequence
                }
            }
            return batch
        }
        for job in batch {
            job.publish()
        }
        let order = batchOrder, actions = batchActions
        batchOrder = []
        batchActions = [:]
        for owner in order {
            actions[owner]?()
        }
    }

    /// From a job's `publish`: runs `action` once the batch being published is done, once per owner however
    /// many of its jobs are in the batch (lay out once for many tiles).
    @MainActor
    func afterBatch(_ owner: AnyObject, _ action: @escaping @MainActor () -> Void) {
        let id = ObjectIdentifier(owner)
        if batchActions[id] == nil {
            batchOrder.append(id)
        }
        batchActions[id] = { MainActor.assumeIsolated { action() } }
    }
}
