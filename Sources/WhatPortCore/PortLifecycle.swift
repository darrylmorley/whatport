import Foundation

// Domain-layer mirror of WhatPortIOKit's RawLifecycleSignal. WhatPortCore
// never imports WhatPortIOKit, so it carries its own copy of the same four
// signal kinds rather than referencing the IOKit layer's type.
public enum LifecycleSignalKind: Sendable, Equatable {
    case attach
    case negotiating
    case contractEstablished
    case transportReady
}

// Deliberately no .connected case: "connected" is just the absence of a
// tracked phase, plus the normal PortState rendering already carrying the
// real link data once one exists.
public enum PortLifecyclePhase: Sendable, Equatable {
    case detecting
    case negotiating
}

public struct PortLifecycleSignalInput: Sendable, Equatable {
    public let portID: Int
    public let signal: LifecycleSignalKind

    public init(portID: Int, signal: LifecycleSignalKind) {
        self.portID = portID
        self.signal = signal
    }
}

// Tracks per-port connection-lifecycle phase from IOAccessoryManager
// notification signals. Those codes are private, undocumented, and observed
// to be noisy: they repeat, and can arrive out of order. So this machine
// never treats them as a strict sequence, only as loose hints with timeout
// backstops to guarantee a phase never gets stuck.
//
// This is an implementation detail of PortManager (which owns the instance
// and the reconciliation clock via applySnapshot); it is public only so the
// test target can exercise it directly.
public struct PortLifecycleStateMachine: Sendable {
    // Signals stop firing partway through a connection more often than they
    // run to completion (empirical corpus behaviour), so a phase that has
    // gone quiet this long is assumed abandoned rather than mid-negotiation.
    public static let staleTimeout: TimeInterval = 3
    // Ceiling on how long any phase may be shown at all, even under
    // continuous non-progressing signal churn that keeps refreshing
    // lastSignalAt: never let the UI show a stuck phase forever.
    public static let maxPhaseDuration: TimeInterval = 6

    private struct Episode {
        var phase: PortLifecyclePhase
        var startedAt: Date
        var lastSignalAt: Date
    }

    private var episodes: [Int: Episode] = [:]

    public init() {}

    public var phases: [Int: PortLifecyclePhase] {
        episodes.mapValues(\.phase)
    }

    // No backward-clock guard needed here: a `now` that is earlier than a
    // previously stored value only ever shortens or restarts an episode
    // (never extends one), and any resulting negative interval is caught by
    // reconcile's own rebase on its next call.
    public mutating func handle(_ signal: LifecycleSignalKind, portID: Int, at now: Date) {
        switch signal {
        case .attach:
            if var episode = episodes[portID] {
                // Forward-only within an episode: a stray attach arriving
                // after negotiating has already started must not downgrade it.
                episode.lastSignalAt = now
                episodes[portID] = episode
            } else {
                episodes[portID] = Episode(phase: .detecting, startedAt: now, lastSignalAt: now)
            }

        case .negotiating, .contractEstablished:
            if var episode = episodes[portID] {
                episode.phase = .negotiating
                episode.lastSignalAt = now
                episodes[portID] = episode
            } else {
                episodes[portID] = Episode(phase: .negotiating, startedAt: now, lastSignalAt: now)
            }

        case .transportReady:
            episodes.removeValue(forKey: portID)
        }
    }

    // Clears tracked ports the caller already knows are done (disconnected or
    // resolved to a live PortState), then expires anything left stale or over
    // the hard ceiling. Called from PortManager.applySnapshot, so the 1s poll
    // (and the debounced connection-notification path feeding it) double as
    // this machine's timeout clock; no separate Timer or Task needed.
    public mutating func reconcile(disconnectedPortIDs: Set<Int>, resolvedPortIDs: Set<Int>, now: Date) {
        for portID in disconnectedPortIDs {
            episodes.removeValue(forKey: portID)
        }
        for portID in resolvedPortIDs {
            episodes.removeValue(forKey: portID)
        }

        // Plain interval comparisons: a backwards clock jump produces a
        // negative interval, which simply never satisfies `>= timeout`, so it
        // can't crash. But left alone a negative interval also means the
        // episode keeps reading as fresh for roughly jump+timeout seconds, so
        // a large backward jump can leave a phase visible far longer than any
        // timeout is meant to allow. Date is wall-clock and can jump backward
        // (NTP correction, manual clock change); rebasing startedAt and
        // lastSignalAt to `now` when either interval goes negative bounds the
        // episode to at most one timeout window measured from the corrected
        // clock, same as if it had just started.
        var expired: [Int] = []
        for (portID, episode) in episodes {
            var episode = episode
            if now < episode.lastSignalAt || now < episode.startedAt {
                episode.startedAt = now
                episode.lastSignalAt = now
                episodes[portID] = episode
                continue
            }
            let sinceSignal = now.timeIntervalSince(episode.lastSignalAt)
            let sinceStart = now.timeIntervalSince(episode.startedAt)
            if sinceSignal >= Self.staleTimeout || sinceStart >= Self.maxPhaseDuration {
                expired.append(portID)
            }
        }
        for portID in expired {
            episodes.removeValue(forKey: portID)
        }
    }
}
