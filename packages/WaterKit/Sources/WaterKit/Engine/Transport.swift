/// Vehicle detection for paddle sports. See docs/metrics.md, "Transport".
///
/// A paddle craft cannot hold a Doppler speed far above any paddler's sprint pace. When
/// every fix stays above `above` for `after` seconds, the watch is in a vehicle (a car,
/// a trailer, a motorboat tow): the session is paused, dated back to the last fix slower
/// than `stoppedBelow`, because every vehicle leg starts from a standstill (the paddler
/// had to get out of the boat). Transport ends at the next fix below `stoppedBelow`.
public enum Transport {
    public struct Config: Sendable, Hashable {
        /// No paddle craft holds this Doppler speed, m/s (28.8 km/h, about 15.6 kn): the K1
        /// 200 m world record averages about 6 m/s, and downwind surfski runs peak around
        /// 7–8 m/s for a few seconds on a wave…
        public var above: Double = 8
        /// …on every fix for at least this long, s.
        public var after: Double = 10
        /// Below this speed the boat (or paddler) is stopped or walking, m/s: transport is
        /// dated back to the last such fix, and ends at the next one.
        public var stoppedBelow: Double = 0.8

        public init() {}
    }
}
