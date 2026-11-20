/// One sport's preferences (docs/PLAN.md §6), shared by the watch and iPhone apps. Every
/// field has a sport-dependent default, and only values that differ from it are stored, so
/// a later change to a default reaches everyone who never touched the setting.
///
/// Storage is a flat key-value store (UserDefaults in the apps) reached through closures,
/// which keeps this type platform-neutral and testable. Key names are a contract with
/// existing installs: `settings.autoPause.<sport>` and `settings.saveWorkout.<sport>`
/// predate this type and keep their names and Bool values.
public struct SportSettings: Sendable, Hashable {
    /// nil means "Automatic": `SpeedUnit.automatic(for:)`.
    public var speedUnit: SpeedUnit?
    /// nil means "Automatic": `DistanceUnit.automatic(for:)`.
    public var distanceUnit: DistanceUnit?
    /// What a live session shows first.
    public var firstScreen: LiveScreen
    public var autoPause: Bool
    /// Save each session to Apple Health as a workout.
    public var savesWorkout: Bool
    /// Alert every this many of the distance unit's main unit (km, nm or mi); nil for off.
    public var distanceAlert: Double?
    /// Minutes of countdown before recording starts; 0 for none.
    public var countdownMinutes: Int
    /// Hidden sports are left out of the start screen.
    public var isHidden: Bool
    /// Fuel burn under way for the fuel estimate, litres per hour; nil for no estimate.
    /// Offered for motorboating (docs/PLAN.md §5).
    public var fuelBurnRate: Double?
    /// Fuel burn for the rest of the moving time, litres per hour; nil for none.
    public var idleFuelBurnRate: Double?
    /// The unit fuel is shown and entered in.
    public var fuelUnit: VolumeUnit
    /// What the Apple Watch Ultra's Action button does while this sport is recording.
    public var actionButton: ActionButtonAction
    /// Doppler speed above which a windsurfing board is treated as planing, m/s.
    public var planingSpeedThreshold: Double

    public init(
        speedUnit: SpeedUnit? = nil, distanceUnit: DistanceUnit? = nil, firstScreen: LiveScreen = .speed,
        autoPause: Bool, savesWorkout: Bool, distanceAlert: Double? = nil, countdownMinutes: Int = 0,
        isHidden: Bool = false, fuelBurnRate: Double? = nil, idleFuelBurnRate: Double? = nil,
        fuelUnit: VolumeUnit = .litres, actionButton: ActionButtonAction = .lap,
        planingSpeedThreshold: Double = defaultPlaningSpeedThreshold
    ) {
        self.speedUnit = speedUnit
        self.distanceUnit = distanceUnit
        self.firstScreen = firstScreen
        self.autoPause = autoPause
        self.savesWorkout = savesWorkout
        self.distanceAlert = distanceAlert
        self.countdownMinutes = countdownMinutes
        self.isHidden = isHidden
        self.fuelBurnRate = fuelBurnRate
        self.idleFuelBurnRate = idleFuelBurnRate
        self.fuelUnit = fuelUnit
        self.actionButton = actionButton
        self.planingSpeedThreshold = planingSpeedThreshold
    }

    /// The defaults: automatic units, speed first, no alerts or countdown, and auto-pause
    /// and Health from `SportProfile.standard(for:)`.
    public static func standard(for sport: Sport) -> SportSettings {
        let profile = SportProfile.standard(for: sport)
        return SportSettings(autoPause: profile.autoPause.enabled, savesWorkout: profile.savesWorkoutByDefault)
    }

    /// Countdown lengths offered, in minutes (0 is off).
    public static let countdownChoices = [0, 1, 3, 5]
    /// Distance alert intervals offered, in the distance unit's main unit.
    public static let distanceAlertChoices: [Double] = [0.25, 0.5, 1, 2, 5, 10]
    public static let defaultPlaningSpeedThreshold = 5.0
    /// Windsurfing thresholds offered in 0.5 m/s steps, displayed in the chosen unit.
    public static let planingSpeedChoices = (4...30).map { Double($0) / 2 }

    public func resolvedSpeedUnit(for sport: Sport) -> SpeedUnit {
        speedUnit ?? .automatic(for: sport)
    }

    public func resolvedDistanceUnit(for sport: Sport) -> DistanceUnit {
        distanceUnit ?? .automatic(for: sport)
    }

    /// The distance alert interval in metres, or nil when off.
    public func distanceAlertMetres(for sport: Sport) -> Double? {
        guard let distanceAlert, distanceAlert > 0, distanceAlert.isFinite else { return nil }
        return resolvedDistanceUnit(for: sport).toSI(distanceAlert)
    }

    /// The fuel model from the burn rates, or nil without a valid under-way rate.
    public var fuelModel: FuelModel? {
        guard let fuelBurnRate else { return nil }
        let model = FuelModel(burnRate: fuelBurnRate, idleBurnRate: idleFuelBurnRate ?? 0)
        return model.isValid ? model : nil
    }

    /// Burn rates above this are treated as typing mistakes, litres per hour.
    public static let maxFuelBurnRate = 2_000.0

    /// The countdown in seconds, or nil when off.
    public var countdownSeconds: Double? {
        countdownMinutes > 0 ? Double(countdownMinutes) * 60 : nil
    }
}

/// What a press of the Apple Watch Ultra's Action button does while a session records.
/// The first press starts the session; this is every press after that.
public enum ActionButtonAction: String, Sendable, Hashable, Codable, CaseIterable {
    case lap
    case mark
    case manOverboard
}

/// What one Action button press does, given the session's state.
public enum ActionButtonPress: Equatable, Sendable {
    /// Rounds a sailing countdown to the nearest minute.
    case syncCountdown
    /// Ends a countdown that cannot sync and starts recording now.
    case startNow
    case lap
    case mark
    case manOverboard
    /// No session is counting down or recording.
    case ignore

    /// During a countdown the press works the countdown; while recording it runs the
    /// sport's chosen action, even while paused (a lap or MOB is never lost to a pause).
    public static func resolve(
        countingDown: Bool, canSync: Bool, isRecording: Bool, action: ActionButtonAction
    ) -> ActionButtonPress {
        if countingDown { return canSync ? .syncCountdown : .startNow }
        guard isRecording else { return .ignore }
        switch action {
        case .lap: return .lap
        case .mark: return .mark
        case .manOverboard: return .manOverboard
        }
    }
}

/// The first page of a live session.
public enum LiveScreen: String, Sendable, Hashable, Codable, CaseIterable {
    case speed
    case distance
    case time
    case heartRate
    case map
}

extension SpeedUnit {
    /// Nautical units on boats and boards, metric for paddling.
    public static func automatic(for sport: Sport) -> SpeedUnit {
        sport.isPaddling ? .kilometresPerHour : .knots
    }
}

extension DistanceUnit {
    /// Nautical units on boats and boards, metric for paddling.
    public static func automatic(for sport: Sport) -> DistanceUnit {
        sport.isPaddling ? .metric : .nauticalMiles
    }
}

// MARK: - Storage

extension SportSettings {
    /// Key names in the settings store.
    public enum Key {
        public static func speedUnit(_ sport: Sport) -> String { "settings.speedUnit.\(sport.rawValue)" }
        public static func distanceUnit(_ sport: Sport) -> String { "settings.distanceUnit.\(sport.rawValue)" }
        public static func firstScreen(_ sport: Sport) -> String { "settings.firstScreen.\(sport.rawValue)" }
        public static func autoPause(_ sport: Sport) -> String { "settings.autoPause.\(sport.rawValue)" }
        public static func saveWorkout(_ sport: Sport) -> String { "settings.saveWorkout.\(sport.rawValue)" }
        public static func distanceAlert(_ sport: Sport) -> String { "settings.distanceAlert.\(sport.rawValue)" }
        public static func countdown(_ sport: Sport) -> String { "settings.countdown.\(sport.rawValue)" }
        public static func hidden(_ sport: Sport) -> String { "settings.hidden.\(sport.rawValue)" }
        public static func fuelBurn(_ sport: Sport) -> String { "settings.fuelBurn.\(sport.rawValue)" }
        public static func fuelIdleBurn(_ sport: Sport) -> String { "settings.fuelIdleBurn.\(sport.rawValue)" }
        public static func fuelUnit(_ sport: Sport) -> String { "settings.fuelUnit.\(sport.rawValue)" }
        public static func actionButton(_ sport: Sport) -> String { "settings.actionButton.\(sport.rawValue)" }
        public static let planingSpeedThreshold = "settings.planingSpeedThreshold.windsurfing"

        /// Units for every sport, before units became per sport.
        public static let legacySpeedUnit = "settings.speedUnit"
        public static let legacyDistanceUnit = "settings.distanceUnit"

        /// Every key of one sport.
        public static func all(_ sport: Sport) -> [String] {
            let shared = [
                speedUnit(sport), distanceUnit(sport), firstScreen(sport), autoPause(sport), saveWorkout(sport),
                distanceAlert(sport), countdown(sport), hidden(sport), fuelBurn(sport), fuelIdleBurn(sport),
                fuelUnit(sport), actionButton(sport),
            ]
            return sport == .windsurfing ? shared + [planingSpeedThreshold] : shared
        }

        /// Every per-sport key of every sport.
        public static var allSports: [String] { Sport.allCases.flatMap(all) }
    }

    /// The stored value for "Automatic" units. Older builds wrote it too.
    public static let automaticValue = "auto"

    /// Reads one sport's settings; missing or unreadable values fall back to the default.
    /// Values may be numbers, Bools or strings (launch arguments arrive as strings).
    public init(sport: Sport, reading value: (String) -> Any?) {
        self = .standard(for: sport)
        if let raw = value(Key.speedUnit(sport)) as? String { speedUnit = SpeedUnit(rawValue: raw) }
        if let raw = value(Key.distanceUnit(sport)) as? String { distanceUnit = DistanceUnit(rawValue: raw) }
        if let raw = value(Key.firstScreen(sport)) as? String, let screen = LiveScreen(rawValue: raw) {
            firstScreen = screen
        }
        if let on = Self.bool(value(Key.autoPause(sport))) { autoPause = on }
        if let on = Self.bool(value(Key.saveWorkout(sport))) { savesWorkout = on }
        if let interval = Self.number(value(Key.distanceAlert(sport))), interval > 0, interval.isFinite {
            distanceAlert = interval
        }
        if let minutes = Self.number(value(Key.countdown(sport))), minutes >= 0, minutes <= 60 {
            countdownMinutes = Int(minutes)
        }
        if let hidden = Self.bool(value(Key.hidden(sport))) { isHidden = hidden }
        if let raw = value(Key.actionButton(sport)) as? String, let action = ActionButtonAction(rawValue: raw) {
            actionButton = action
        }
        fuelBurnRate = Self.burnRate(value(Key.fuelBurn(sport)))
        idleFuelBurnRate = Self.burnRate(value(Key.fuelIdleBurn(sport)), allowZero: true)
        if let raw = value(Key.fuelUnit(sport)) as? String, let unit = VolumeUnit(rawValue: raw) { fuelUnit = unit }
        if sport == .windsurfing, let threshold = Self.number(value(Key.planingSpeedThreshold)),
            Self.planingSpeedChoices.contains(threshold)
        {
            planingSpeedThreshold = threshold
        }
    }

    private static func burnRate(_ value: Any?, allowZero: Bool = false) -> Double? {
        guard let rate = number(value), rate.isFinite, rate <= maxFuelBurnRate, allowZero ? rate >= 0 : rate > 0
        else { return nil }
        return rate
    }

    /// Writes one sport's settings: a value equal to the default is removed (nil), so the
    /// store holds only the user's changes.
    public func write(sport: Sport, to set: (String, Any?) -> Void) {
        let standard = Self.standard(for: sport)
        set(Key.speedUnit(sport), speedUnit?.rawValue)
        set(Key.distanceUnit(sport), distanceUnit?.rawValue)
        set(Key.firstScreen(sport), firstScreen == standard.firstScreen ? nil : firstScreen.rawValue)
        set(Key.autoPause(sport), autoPause == standard.autoPause ? nil : autoPause)
        set(Key.saveWorkout(sport), savesWorkout == standard.savesWorkout ? nil : savesWorkout)
        set(Key.distanceAlert(sport), distanceAlert)
        set(Key.countdown(sport), countdownMinutes == 0 ? nil : countdownMinutes)
        set(Key.hidden(sport), isHidden ? true : nil)
        set(Key.fuelBurn(sport), fuelBurnRate)
        set(Key.fuelIdleBurn(sport), idleFuelBurnRate)
        set(Key.fuelUnit(sport), fuelUnit == standard.fuelUnit ? nil : fuelUnit.rawValue)
        set(Key.actionButton(sport), actionButton == standard.actionButton ? nil : actionButton.rawValue)
        if sport == .windsurfing {
            let custom =
                planingSpeedThreshold != standard.planingSpeedThreshold
                && Self.planingSpeedChoices.contains(planingSpeedThreshold)
            set(Key.planingSpeedThreshold, custom ? planingSpeedThreshold : nil)
        }
    }

    /// Moves units chosen before they were per sport onto every sport that has no unit of
    /// its own, then removes the old keys. Safe to run on every launch.
    public static func migrateLegacyUnits(reading value: (String) -> Any?, writing set: (String, Any?) -> Void) {
        func migrate(_ legacy: String, _ key: (Sport) -> String, valid: (String) -> Bool) {
            guard let raw = value(legacy) as? String else {
                if value(legacy) != nil { set(legacy, nil) }
                return
            }
            if valid(raw) {
                for sport in Sport.allCases where value(key(sport)) == nil { set(key(sport), raw) }
            }
            set(legacy, nil)
        }
        migrate(Key.legacySpeedUnit, Key.speedUnit) { SpeedUnit(rawValue: $0) != nil }
        migrate(Key.legacyDistanceUnit, Key.distanceUnit) { DistanceUnit(rawValue: $0) != nil }
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as Int64: Double(value)
        case let value as String: Double(value)
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as Int: value != 0
        case let value as String:
            switch value.lowercased() {
            case "1", "yes", "true": true
            case "0", "no", "false": false
            default: nil
            }
        default: nil
        }
    }
}

// MARK: - Start list

/// Which sports the start screen shows, in what order.
public enum SportList {
    /// Visible sports, most recently used first; sports never used follow in their usual
    /// order. `lastUsed` holds unix times.
    public static func ordered(lastUsed: [Sport: Double], hidden: Set<Sport>) -> [Sport] {
        let visible = Sport.allCases.filter { !hidden.contains($0) }
        let shown = visible.isEmpty ? Sport.allCases : visible
        return shown.enumerated()
            .sorted { a, b in
                switch (lastUsed[a.element], lastUsed[b.element]) {
                case (let x?, let y?) where x != y: x > y
                case (.some, nil): true
                case (nil, .some): false
                default: a.offset < b.offset
                }
            }
            .map(\.element)
    }

    /// Visible sports in the user's own order (set by dragging on the start screen).
    /// Sports missing from `custom` (added in a later build) follow in their usual order.
    public static func ordered(custom: [Sport], hidden: Set<Sport>) -> [Sport] {
        let visible = Sport.allCases.filter { !hidden.contains($0) }
        let shown = visible.isEmpty ? Sport.allCases : visible
        let known = complete(custom)
        return known.filter(shown.contains)
    }

    /// The full custom order after the visible sports were rearranged into `visible`.
    /// Hidden sports keep their slots, so showing one again puts it back where it was.
    public static func reordered(custom: [Sport], visible: [Sport]) -> [Sport] {
        var order = complete(custom)
        let slots = order.indices.filter { visible.contains(order[$0]) }
        guard slots.count == visible.count else { return order }
        for (slot, sport) in zip(slots, visible) { order[slot] = sport }
        return order
    }

    /// `custom` without duplicates, then every sport it lacks in the usual order.
    private static func complete(_ custom: [Sport]) -> [Sport] {
        var seen = Set<Sport>()
        let unique = custom.filter { seen.insert($0).inserted }
        return unique + Sport.allCases.filter { !seen.contains($0) }
    }

    /// Whether `sport` may be hidden: at least one sport must stay visible.
    public static func canHide(_ sport: Sport, hidden: Set<Sport>) -> Bool {
        hidden.contains(sport) || Sport.allCases.contains { $0 != sport && !hidden.contains($0) }
    }
}
