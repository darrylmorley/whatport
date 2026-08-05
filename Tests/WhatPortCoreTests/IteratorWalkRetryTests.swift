import Testing
@testable import WhatPortCore

@Test func iteratorWalkRetryRunsOnceWhenValid() {
    var walkCount = 0

    let results = IteratorWalkRetry.retry(
        isValid: { true },
        reset: { Issue.record("reset should not be called when the walk stays valid") },
        walk: {
            walkCount += 1
            return [1, 2, 3]
        }
    )

    #expect(results == [1, 2, 3])
    #expect(walkCount == 1)
}

@Test func iteratorWalkRetryStopsAfterBoundWhenAlwaysInvalid() {
    var walkCount = 0
    var resetCount = 0

    let results = IteratorWalkRetry.retry(
        maxAttempts: 3,
        isValid: { false },
        reset: { resetCount += 1 },
        walk: {
            walkCount += 1
            return [walkCount]
        }
    )

    // 3 attempts made, but only 2 resets: no reset after the final attempt.
    #expect(walkCount == 3)
    #expect(resetCount == 2)
    // Degraded data beats none: the last attempt's results are returned.
    #expect(results == [3])
}

@Test func iteratorWalkRetryDiscardsPartialResultsFromInvalidatedAttempts() {
    var discarded: [Int] = []
    var attempt = 0

    let results = IteratorWalkRetry.retry(
        isValid: { attempt > 1 },
        reset: {},
        discard: { discarded.append($0) },
        walk: {
            attempt += 1
            return attempt == 1 ? [99] : [1, 2]
        }
    )

    // The first attempt's partial result was discarded, not merged into the
    // final answer.
    #expect(discarded == [99])
    #expect(results == [1, 2])
}
