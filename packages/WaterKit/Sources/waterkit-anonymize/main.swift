import Foundation
import WaterKit

// waterkit-anonymize: hide where and when a recording was made (see Anonymizer), or
// check that recordings are anonymized.
//
//   waterkit-anonymize <input> <output>
//   waterkit-anonymize --check <path>...

let usage = """
    Usage:
      waterkit-anonymize <input> <output>
          Anonymize a raw recording folder (output: a new folder, streams gzipped)
          or a track file (output: track.json.gz).
      waterkit-anonymize --check <path>...
          Check recordings are anonymized. A path may be a recording folder, a track
          file, or a folder searched recursively (e.g. fixtures/). Exits 1 on problems.

    Positions move to a fake origin (distances and bearings kept), times move to
    2000-01-01, the session ID is replaced, and altitude and free-text data are dropped.

    """

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message.hasSuffix("\n") ? message : message + "\n").utf8))
    exit(code)
}

let fm = FileManager.default

func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return fm.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
}

func isTrackFile(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return name.hasSuffix(".json.gz")
        || (name.hasSuffix(".json") && name != RawFormat.metaFileName
            && name != "labels.json")
}

/// Recording folders (containing meta.json) and track files under `root`.
func recordings(under root: URL) -> [URL] {
    if !isDirectory(root) { return [root] }
    if fm.fileExists(atPath: root.appendingPathComponent(RawFormat.metaFileName).path) { return [root] }
    let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return children.sorted { $0.path < $1.path }.flatMap { child -> [URL] in
        if isDirectory(child) { return recordings(under: child) }
        return isTrackFile(child) ? [child] : []
    }
}

func check(_ paths: [String]) -> Never {
    var failures = 0
    var checked = 0
    for path in paths {
        for url in recordings(under: URL(fileURLWithPath: path)) {
            checked += 1
            do {
                let problems =
                    isDirectory(url)
                    ? FixtureCheck.problems(in: try RawSessionReader.read(folder: url))
                    : FixtureCheck.problems(in: try TrackCodec.decode(Data(contentsOf: url)))
                if problems.isEmpty {
                    print("ok    \(url.path)")
                } else {
                    failures += 1
                    print("FAIL  \(url.path)")
                    for problem in problems { print("      - \(problem)") }
                }
            } catch {
                failures += 1
                print("FAIL  \(url.path)\n      - unreadable: \(error)")
            }
        }
    }
    print("Checked \(checked) recording(s), \(failures) failed.")
    exit(failures == 0 ? 0 : 1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--help") {
    print(usage, terminator: "")
    exit(arguments.isEmpty ? 2 : 0)
}
if arguments[0] == "--check" {
    guard arguments.count > 1 else { fail(usage, 2) }
    check(Array(arguments.dropFirst()))
}
guard arguments.count == 2, !arguments.contains(where: { $0.hasPrefix("-") }) else { fail(usage, 2) }

let input = URL(fileURLWithPath: arguments[0])
var output = URL(fileURLWithPath: arguments[1])
guard fm.fileExists(atPath: input.path) else { fail("No such file or folder: \(input.path)", 1) }
guard !fm.fileExists(atPath: output.path) else { fail("Output already exists: \(output.path)", 1) }

do {
    let anonymizer = Anonymizer()
    if isDirectory(input) {
        let session = anonymizer.anonymize(try RawSessionReader.read(folder: input))
        try RawSessionWriter.write(session, to: output)
        let problems = FixtureCheck.problems(in: try RawSessionReader.read(folder: output))
        guard problems.isEmpty else { fail("Anonymized output failed its check: \(problems)", 1) }
    } else {
        if output.pathExtension != "gz" { output.appendPathExtension("gz") }
        let track = anonymizer.anonymize(try TrackCodec.decode(Data(contentsOf: input)))
        try TrackCodec.encode(track).write(to: output)
        let problems = FixtureCheck.problems(in: try TrackCodec.decode(Data(contentsOf: output)))
        guard problems.isEmpty else { fail("Anonymized output failed its check: \(problems)", 1) }
    }
    print("Wrote \(output.path) (session \(anonymizer.sessionId.uuidString.lowercased()))")
} catch {
    fail("Could not anonymize \(input.path): \(error)", 1)
}
