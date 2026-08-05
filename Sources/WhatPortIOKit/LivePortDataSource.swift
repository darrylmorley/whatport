import Foundation
import WhatPortCore
import os

// The production implementation of PortDataSource.
// Combines notification-driven state changes with timer-based power polling
// into a single AsyncStream of snapshots.
//
// AsyncStream is Swift's way to bridge callback-based or timer-based events
// into async/await code. You create one with a "continuation" that you yield
// values into. The consumer awaits values with `for await snapshot in stream`.
//
// Lifecycle:
// 1. start() opens the SMC connection and begins the poll timer + notifications
// 2. On notification (debounced): reads all state, yields a snapshot
// 3. On poll tick (pollInterval): reads all state, yields a snapshot
// 4. stop() cancels everything and closes the SMC connection
//
// Notifications give sub-second response to plug/unplug events.
// The poll timer catches everything else (power changes, transport
// state updates) and acts as a safety net for any missed notifications.
//
// @unchecked Sendable: we manage thread safety manually via the serial queue
// and nonisolated(unsafe) markers. The PortNotifier already dispatches on its
// own queue, and we access mutable state only from controlled contexts.

public final class LivePortDataSource: @unchecked Sendable, PortDataSource {
    // How often the poll timer reads state. Per-port power-OUT now comes from the
    // SMC, which updates ~1 Hz, so we poll at 1s to track the live draw (the old
    // PowerOutDetails source froze under load, making a faster poll pointless).
    private static let pollInterval: Duration = .seconds(1)

    private let notifier = PortNotifier()
    // One persisted SMC connection, opened in start() and closed in stop(),
    // reused for every snapshot instead of re-opening per poll. Its reads are
    // lock-guarded so the notifier callback and the poll task can share it.
    private let smc = SMCPowerReader()
    private nonisolated(unsafe) var pollTask: Task<Void, Never>?
    private nonisolated(unsafe) var continuation: AsyncStream<PortSnapshot>.Continuation?
    private nonisolated(unsafe) var lifecycleContinuation: AsyncStream<RawPortLifecycleEvent>.Continuation?
    // Guards start()/stop() as an atomic compare-and-set: a plain Bool plus a
    // separate guard-then-write would let two racing callers (e.g. an
    // AppDelegate terminate racing a stream's onTermination) both read
    // "running" before either writes, and both proceed.
    private let runningLock = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func observePortUpdates() -> AsyncStream<PortSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation

            // [weak self]: without it, this closure (owned by the
            // continuation) captures self strongly, and self holds the
            // continuation, so a stream created and then dropped without
            // ever calling stop() (as the smoke test does) forms a retain
            // cycle that never deinits.
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stop()
            }
        }
    }

    // Deliberate contract: terminating either stream, this one or
    // observePortUpdates(), stops the whole data source, not just that one
    // stream. There's a single lifetime consumer (the app), not independent
    // per-stream subscribers, so this is not a per-stream unsubscribe.
    public func observeLifecycleEvents() -> AsyncStream<RawPortLifecycleEvent> {
        // Bounded, not unbounded: IOAccessoryManager can fire a burst of
        // lifecycle messages per plug/unplug, and unlike snapshots (one per
        // debounced refresh) there is no coalescing on this path by design
        // (low latency is the point). bufferingNewest(16) caps memory if a
        // consumer falls behind and drops the oldest, keeping the most
        // recent (and most relevant) events rather than growing forever.
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            self.lifecycleContinuation = continuation

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stop()
            }
        }
    }

    public func start() async {
        // Atomic compare-and-set (see runningLock's doc comment): flips to
        // running and reports whether it was already running.
        let wasRunning = runningLock.withLock { running -> Bool in
            let was = running
            running = true
            return was
        }
        guard !wasRunning else { return }

        // Open the shared SMC connection once for the session.
        smc.open()

        // Yield an initial snapshot immediately
        yieldSnapshot()

        // Start notification-driven updates
        notifier.start(
            onChange: { [weak self] in
                self?.yieldSnapshot()
            },
            onLifecycleEvent: { [weak self] event in
                self?.lifecycleContinuation?.yield(event)
            }
        )

        // Start polling (pollInterval). Reads all state, not just power.
        // Acts as a safety net alongside notifications and drives live power.
        startPollTimer()
    }

    // Call this from the app layer when the system wakes from sleep.
    // NSWorkspace.didWakeNotification lives in AppKit, so the app target
    // registers for it and calls this method.
    public func handleWake() {
        yieldSnapshot()
    }

    public func stop() {
        // Same atomic compare-and-set as start(): AppDelegate's terminate
        // handler and an AsyncStream's onTermination (fired when a consumer
        // stops iterating) can both reach here for the same session, e.g.
        // app quit racing a stream finishing. Without an atomic flip, two
        // racing callers could both read "running" true and both proceed,
        // re-finishing already-nilled continuations and re-closing an
        // already-closed SMC connection.
        let wasRunning = runningLock.withLock { running -> Bool in
            let was = running
            running = false
            return was
        }
        guard wasRunning else { return }
        notifier.stop()
        pollTask?.cancel()
        pollTask = nil
        smc.close()
        continuation?.finish()
        continuation = nil
        lifecycleContinuation?.finish()
        lifecycleContinuation = nil
    }

    private func yieldSnapshot() {
        let snapshot = SnapshotReader.takeSnapshot(smc: smc)
        continuation?.yield(snapshot)
    }

    private func startPollTimer() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { break }
                guard let self, self.runningLock.withLock({ $0 }) else { break }
                self.yieldSnapshot()
            }
        }
    }
}
