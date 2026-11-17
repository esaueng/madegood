/// A sport a session can be recorded as. Raw values are the wire names used in
/// files and the API; never change an existing one.
public enum Sport: String, Sendable, Hashable, Codable, CaseIterable {
    case sailing
    case windsurfing
    case motorboating
    case kayak
    case canoe
    case sup

    public var isPaddling: Bool {
        switch self {
        case .kayak, .canoe, .sup: true
        case .sailing, .windsurfing, .motorboating: false
        }
    }
}
