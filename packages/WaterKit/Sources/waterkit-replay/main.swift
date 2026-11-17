import Foundation
import WaterKit

// waterkit-replay: print basic statistics for a raw recording folder or a track file.
//
//   swift run waterkit-replay <session-folder | track.json[.gz]> [--sport <sport>] [--json] [--gpx <out-path>]

let usage = """
    Usage: waterkit-replay <path> [--sport <sport>] [--json] [--gpx <out-path>]

      <path>           A raw recording folder (with meta.json; unzip a shared .zip first)
                       or a track v1 file (track.json or track.json.gz).
      --sport <sport>  Treat the session as this sport: \(Sport.allCases.map(\.rawValue).joined(separator: ", ")).
      --json           Print machine-readable JSON instead of text.
      --gpx <out-path> Also write the session's track as GPX 1.1 to <out-path>.

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

let options: ReplayArguments
do {
    switch try ReplayArguments.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(usage, terminator: "")
        exit(ExitCode.ok.rawValue)
    case .run(let parsed):
        options = parsed
    }
} catch {
    fail("\(error)\n\n" + usage, .usage)
}
let path = options.path
let sportOverride = options.sport
let asJSON = options.json
let gpxPath = options.gpxPath

let url = URL(fileURLWithPath: path)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
    fail("No such file or folder: \(path)", .failed)
}

do {
    var stats: SessionStats
    var track: Track
    if isDirectory.boolValue {
        var session = try RawSessionReader.read(folder: url)
        if let sportOverride { session.meta.sport = sportOverride }
        stats = SessionStats(session: session)
        track = session.track()
    } else {
        track = try TrackCodec.decode(Data(contentsOf: url))
        if let sportOverride { track.sport = sportOverride }
        stats = SessionStats(track: track)
    }
    if let gpxPath {
        do {
            try GPXWriter().data(for: track).write(to: URL(fileURLWithPath: gpxPath), options: .atomic)
        } catch {
            fail("Could not write \(gpxPath): \(error)", .failed)
        }
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
