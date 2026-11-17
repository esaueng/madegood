import Foundation
import WaterKit

// waterkit-replay: print basic statistics for a raw recording folder or a track file.
//
//   swift run waterkit-replay <session-folder | track.json[.gz]> [--sport <sport>] [--json]

let usage = """
    Usage: waterkit-replay <path> [--sport <sport>] [--json]

      <path>           A raw recording folder (with meta.json; unzip a shared .zip first)
                       or a track v1 file (track.json or track.json.gz).
      --sport <sport>  Treat the session as this sport: \(Sport.allCases.map(\.rawValue).joined(separator: ", ")).
      --json           Print machine-readable JSON instead of text.

    """

enum ExitCode: Int32 {
    case ok = 0
    case failed = 1
    case usage = 2
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data((message.hasSuffix("\n") ? message : message + "\n").utf8))
    exit(code.rawValue)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var path: String?
var sportOverride: Sport?
var asJSON = false

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "-h", "--help":
        print(usage, terminator: "")
        exit(ExitCode.ok.rawValue)
    case "--json":
        asJSON = true
    case "--sport":
        guard let value = arguments.first else { fail("--sport needs a value\n\n" + usage, .usage) }
        arguments.removeFirst()
        guard let sport = Sport(rawValue: value) else { fail("Unknown sport \"\(value)\"\n\n" + usage, .usage) }
        sportOverride = sport
    default:
        if argument.hasPrefix("-") { fail("Unknown option \(argument)\n\n" + usage, .usage) }
        if path != nil { fail("Only one path is allowed\n\n" + usage, .usage) }
        path = argument
    }
}

guard let path else { fail(usage, .usage) }

let url = URL(fileURLWithPath: path)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
    fail("No such file or folder: \(path)", .failed)
}

do {
    var stats: SessionStats
    if isDirectory.boolValue {
        var session = try RawSessionReader.read(folder: url)
        if let sportOverride { session.meta.sport = sportOverride }
        stats = SessionStats(session: session)
    } else {
        var track = try TrackCodec.decode(Data(contentsOf: url))
        if let sportOverride { track.sport = sportOverride }
        stats = SessionStats(track: track)
    }
    if asJSON {
        FileHandle.standardOutput.write(try stats.jsonReport())
        print()
    } else {
        print(stats.textReport(), terminator: "")
    }
} catch {
    fail("Could not read \(path): \(error)", .failed)
}
