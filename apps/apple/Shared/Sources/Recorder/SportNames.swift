import WaterKit

extension Sport {
    var displayName: String {
        switch self {
        case .sailing: "Sailing"
        case .windsurfing: "Windsurfing"
        case .motorboating: "Motorboating"
        case .kayak: "Kayak"
        case .canoe: "Canoe"
        case .sup: "SUP"
        }
    }

    var symbolName: String {
        switch self {
        case .sailing: "sailboat"
        case .windsurfing: "wind"
        case .motorboating: "ferry"
        case .kayak, .canoe: "oar.2.crossed"
        case .sup: "figure.stand"
        }
    }
}

extension Sport: @retroactive Identifiable {
    public var id: String { rawValue }
}
