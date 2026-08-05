import Foundation

// Bounded retry policy for iterator walks that can be invalidated mid-walk.
//
// IOKit's IOIteratorNext returns 0 both when a walk finishes normally and
// when the registry mutated underneath it (a device plugged or unplugged
// while WhatPort was reading). The two cases look identical from the return
// value alone, so a walk that was silently cut short reads as complete. Per
// IOKitLib.h, the caller must check IOIteratorIsValid once the walk ends: an
// invalid iterator can be reset and the walk retried.
//
// This is the pure retry policy behind that check, kept free of IOKit so it
// can be tested without real hardware. Callers supply IOKit-specific
// closures for validity, reset, the walk itself, and (optionally) releasing
// resources held by a discarded attempt's partial results.
public enum IteratorWalkRetry {
    /// Run `walk`, retrying up to `maxAttempts` times if the iterator was
    /// invalidated mid-walk.
    ///
    /// After each attempt: if `isValid` reports the iterator still valid, or
    /// this was the last attempt, that attempt's results are returned as
    /// final. Otherwise the attempt's results are handed to `discard` one by
    /// one, `reset` is called, and the walk is retried.
    ///
    /// Bounded so continuous plug/unplug activity can't loop forever. The
    /// last attempt's results are returned even if it was also invalidated:
    /// degraded data beats none.
    public static func retry<T>(
        maxAttempts: Int = 3,
        isValid: () -> Bool,
        reset: () -> Void,
        discard: (T) -> Void = { _ in },
        walk: () -> [T]
    ) -> [T] {
        var results: [T] = []
        for attempt in 1...max(1, maxAttempts) {
            results = walk()
            let isLastAttempt = attempt == max(1, maxAttempts)
            if isValid() || isLastAttempt { return results }
            results.forEach(discard)
            reset()
        }
        return results
    }
}
