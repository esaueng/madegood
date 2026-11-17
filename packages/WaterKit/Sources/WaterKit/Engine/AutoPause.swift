/// Automatic pause detection from Doppler speed, with hysteresis and hold times so a
/// single slow or fast fix does not flip the state. See docs/metrics.md, "Auto-pause".
///
/// When a pause or resume is confirmed, it is dated back to when the speed first
/// crossed the threshold, so moving time and distance exclude the slow stretch that led
/// up to the pause and include the stretch that led up to the resume.
public enum AutoPause {
    public struct Config: Sendable, Hashable {
        public var enabled: Bool
        /// Pause when speed stays below this, m/s…
        public var pauseBelow: Double = 0.4
        /// …for at least this long, s.
        public var pauseAfter: Double = 10
        /// Resume when speed stays at or above this, m/s…
        public var resumeAbove: Double = 0.8
        /// …for at least this long, s.
        public var resumeAfter: Double = 3

        public init(enabled: Bool) {
            self.enabled = enabled
        }
    }
}
