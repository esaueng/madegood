import Foundation
import WaterKit

// waterkit-anonymize: hide where and when a recording was made (see Anonymizer), or
// check that recordings are anonymized.
//
//   waterkit-anonymize <input> <output> [--labels <labels.json>]
//   waterkit-anonymize --check <path>...

let usage = """
    Usage:
      waterkit-anonymize <input> <output> [--labels <labels.json>]
          Anonymize a raw recording folder (output: a new folder, streams gzipped)
          or a track file (output: track.json.gz). With --labels (recording folders
          only), check reviewed labels against the recording and write them into the
          output as labels.json; drafts are rejected.
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

func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
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
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(RawFormat.metaFileName).path) {
        return [root]
    }
    let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
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
                    ? FixtureCheck.problems(inFolder: url)
                    : FixtureCheck.problems(inTrackFile: try Data(contentsOf: url))
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
var positional: [String] = []
var labelsPath: String?
var index = 0
while index < arguments.count {
    if arguments[index] == "--labels" {
        guard index + 1 < arguments.count, labelsPath == nil else { fail(usage, 2) }
        labelsPath = arguments[index + 1]
        index += 2
        continue
    }
    guard !arguments[index].hasPrefix("-") else { fail(usage, 2) }
    positional.append(arguments[index])
    index += 1
}
guard positional.count == 2 else { fail(usage, 2) }

let input = URL(fileURLWithPath: positional[0])
var output = URL(fileURLWithPath: positional[1])
guard FileManager.default.fileExists(atPath: input.path) else { fail("No such file or folder: \(input.path)", 1) }
guard !FileManager.default.fileExists(atPath: output.path) else { fail("Output already exists: \(output.path)", 1) }

do {
    let anonymizer = Anonymizer()
    if isDirectory(input) {
        let labels = try labelsPath.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        try anonymizer.exportFixture(from: input, to: output, labels: labels)
    } else {
        guard labelsPath == nil else { fail("--labels needs a raw recording folder (stroke labels need motion)", 2) }
        if output.pathExtension != "gz" { output.appendPathExtension("gz") }
        let track = anonymizer.anonymize(try TrackCodec.decode(Data(contentsOf: input)))
        try TrackCodec.encode(track).write(to: output)
        let problems = FixtureCheck.problems(inTrackFile: try Data(contentsOf: output))
        guard problems.isEmpty else { fail("Anonymized output failed its check: \(problems)", 1) }
    }
    print("Wrote \(output.path) (session \(anonymizer.sessionId.uuidString.lowercased()))")
} catch {
    fail("Could not anonymize \(input.path): \(error)", 1)
}
