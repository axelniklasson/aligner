import Foundation

/// Counts consecutive quick press-and-release taps of the draw modifier. A tap
/// only counts if nothing else happened while it was down — otherwise typing
/// two capital letters in a row ("PR") would count as a double-tap.
struct TapDetector {
    /// Longest a single press may last to count as a tap.
    var maxTapDuration: TimeInterval = 0.35
    /// Longest pause between one tap's release and the next tap's press for
    /// them to belong to the same sequence.
    var maxGap: TimeInterval = 0.4

    private var holdStart: TimeInterval?
    private var sequenceStart: TimeInterval?
    private var lastRelease: TimeInterval?
    private var count = 0

    /// Feed every held/released transition. `otherInputSince(interval)` must
    /// report whether any non-modifier input happened in the last `interval`
    /// seconds. Returns the length of the tap sequence just completed
    /// (1 for a single tap, 2 for a double-tap, …) or 0 if this release was
    /// not a clean tap.
    mutating func update(
        held: Bool,
        now: TimeInterval,
        otherInputSince: (TimeInterval) -> Bool
    ) -> Int {
        if held {
            holdStart = now
            return 0
        }
        guard let start = holdStart else { return 0 }
        holdStart = nil

        let duration = now - start
        guard duration <= maxTapDuration else {
            reset()
            return 0
        }

        if let last = lastRelease, let first = sequenceStart, start - last <= maxGap {
            // Continuing a sequence: nothing else may have happened since it began.
            guard !otherInputSince(now - first) else {
                reset()
                return 0
            }
            count += 1
        } else {
            guard !otherInputSince(duration) else {
                reset()
                return 0
            }
            count = 1
            sequenceStart = start
        }
        lastRelease = now
        return count
    }

    private mutating func reset() {
        count = 0
        sequenceStart = nil
        lastRelease = nil
    }
}
