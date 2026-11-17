/// Command-line arguments for `waterkit-replay`, parsed here so the rules are testable.
public struct ReplayArguments: Sendable, Hashable {
    public enum Parsed: Sendable, Hashable {
        case help
        case run(ReplayArguments)
    }

    public struct Error: Swift.Error, Sendable, Hashable, CustomStringConvertible {
        public var description: String
    }

    public var path: String
    public var sport: Sport?
    public var json = false
    public var gpxPath: String?

    public init(path: String, sport: Sport? = nil, json: Bool = false, gpxPath: String? = nil) {
        self.path = path
        self.sport = sport
        self.json = json
        self.gpxPath = gpxPath
    }

    /// Parses the arguments after the program name.
    public static func parse(_ arguments: [String]) throws(Error) -> Parsed {
        var remaining = arguments[...]
        var path: String?
        var sport: Sport?
        var json = false
        var gpxPath: String?

        // An option's value may not look like an option, so `--gpx --json` is an error
        // rather than a GPX file named "--json". Use ./-name for a file starting with -.
        func value(for option: String, _ what: String) throws(Error) -> String {
            guard let next = remaining.first, !next.hasPrefix("-") else {
                throw Error(description: "\(option) needs \(what)")
            }
            remaining.removeFirst()
            return next
        }

        while let argument = remaining.popFirst() {
            switch argument {
            case "-h", "--help":
                return .help
            case "--json":
                json = true
            case "--sport":
                let name = try value(for: "--sport", "a value")
                guard let parsed = Sport(rawValue: name) else { throw Error(description: "Unknown sport \"\(name)\"") }
                sport = parsed
            case "--gpx":
                gpxPath = try value(for: "--gpx", "an output path")
            default:
                if argument.hasPrefix("-") { throw Error(description: "Unknown option \(argument)") }
                if path != nil { throw Error(description: "Only one path is allowed") }
                path = argument
            }
        }
        guard let path else { throw Error(description: "A path is required") }
        return .run(ReplayArguments(path: path, sport: sport, json: json, gpxPath: gpxPath))
    }
}
