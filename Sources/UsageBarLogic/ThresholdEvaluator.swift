import Foundation

/// Pure logic for deciding when to fire a usage-threshold notification.
///
/// Extracted into its own type so it can be unit-tested without touching
/// `UNUserNotificationCenter` or `UserDefaults`. The caller is responsible
/// for reading and writing the persisted "last notified threshold" state.
public struct ThresholdEvaluator {

    public struct Decision: Equatable {
        /// The threshold to fire a notification for, or `nil` if nothing fires.
        public let notify: Int?
        /// The value the caller should persist as the new "last notified
        /// threshold". Equal to the input when no state change is needed.
        public let newLastNotified: Int
    }

    /// Given the current usage percent and the highest threshold previously
    /// notified about, decide whether to fire a new notification and what
    /// the new state should be.
    ///
    /// Rules:
    /// - Fire on the *highest* newly-crossed threshold. (A jump from 0% to
    ///   80% notifies for 75%, not 50% — avoid stacking banners.)
    /// - Don't re-fire for a threshold the caller has already been notified
    ///   about, even if the current percent still exceeds it.
    /// - When usage drops below the lowest threshold (new billing cycle),
    ///   reset the persisted state to 0 so future crossings re-notify.
    public static func evaluate(
        percent: Int,
        lastNotified: Int,
        thresholds: [Int] = [50, 75, 90]
    ) -> Decision {
        let sorted = thresholds.sorted(by: >)

        for threshold in sorted {
            if percent >= threshold && threshold > lastNotified {
                return Decision(notify: threshold, newLastNotified: threshold)
            }
        }

        if let lowest = thresholds.min(),
           percent < lowest,
           lastNotified > 0 {
            return Decision(notify: nil, newLastNotified: 0)
        }

        return Decision(notify: nil, newLastNotified: lastNotified)
    }
}
