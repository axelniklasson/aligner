import Foundation

/// Recognises two quick press-and-release taps of the draw modifier. A tap only
/// counts if nothing else happened while it was down — otherwise typing two
/// capital letters in a row ("PR") would count as a double-tap.
struct DoubleTapDetector {
    /// Longest a single press may last to count as a tap.
    var maxTapDuration: TimeInterval = 0.35
    /// Longest the whole gesture (first press → second release) may take.
    var maxSpan: TimeInterval = 0.7

    private var holdStart: TimeInterval?
    private var firstTapStart: TimeInterval?

    /// Feed every held/released transition. `otherInputSince(interval)` must
    /// report whether any non-modifier input happened in the last `interval`
    /// seconds. Returns true when a double-tap completes.
    mutating func update(
        held: Bool,
        now: TimeInterval,
        otherInputSince: (TimeInterval) -> Bool
    ) -> Bool {
        if held {
            holdStart = now
            return false
        }
        guard let start = holdStart else { return false }
        holdStart = nil

        let duration = now - start
        guard duration <= maxTapDuration else {
            firstTapStart = nil
            return false
        }

        if let first = firstTapStart, now - first <= maxSpan {
            firstTapStart = nil
            // Nothing else may have happened since the first tap began.
            return !otherInputSince(now - first)
        }

        firstTapStart = otherInputSince(duration) ? nil : start
        return false
    }
}
