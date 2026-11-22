import Foundation
import WaterKit

// waterkit-label: draft stroke labels for a paddling recording, review them in a local
// page, and score the app against reviewed labels. See fixtures/README.md.

let usage = """
    Usage:
      waterkit-label draft <recording-folder> <output-folder> [--labels <labels.json>] [--force]
          Write labels.draft.json (the detector's candidate strokes, unreviewed) and
          review.html (a self-contained page to correct them) into the output folder.
          With --labels, the page starts from those labels instead and no draft is written.
      waterkit-label score <recording-folder> <labels.json>
          Compare session detail's stroke count and rate with the labels (PLAN §5:
          count within ±3 %, rate within ±2 SPM). Exits 1 when either is outside.

    Label times are seconds since the session start. Drafts are never ground truth:
    a person has to review every stroke before the labels go into a fixture.

    """

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message.hasSuffix("\n") ? message : message + "\n").utf8))
    exit(code)
}

func readPaddling(_ path: String) -> RawSession {
    let folder = URL(fileURLWithPath: path)
    let session: RawSession
    do {
        session = try RawSessionReader.read(folder: folder)
    } catch {
        fail("Could not read the recording \(path): \(error)")
    }
    guard session.meta.sport.isPaddling else {
        fail("\(path) is a \(session.meta.sport.rawValue) recording; stroke labels are for kayak, canoe and SUP.")
    }
    guard !session.motion.isEmpty else { fail("\(path) has no motion stream; strokes need raw wrist motion.") }
    if !session.issues.isEmpty {
        FileHandle.standardError.write(Data("warning: the reader skipped data: \(session.issues)\n".utf8))
    }
    return session
}

func readLabels(_ path: String) -> FixtureLabelsFile {
    do {
        return try JSONDecoder().decode(FixtureLabelsFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        fail("Could not read labels \(path): \(error)")
    }
}

func draft(_ arguments: [String]) {
    var positional: [String] = []
    var labelsPath: String?
    var force = false
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--labels":
            guard index + 1 < arguments.count else { fail("--labels needs a file", 2) }
            labelsPath = arguments[index + 1]
            index += 1
        case "--force": force = true
        default:
            guard !argument.hasPrefix("-") else { fail(usage, 2) }
            positional.append(argument)
        }
        index += 1
    }
    guard positional.count == 2 else { fail(usage, 2) }
    let session = readPaddling(positional[0])
    let output = URL(fileURLWithPath: positional[1])
    let draftURL = output.appendingPathComponent("labels.draft.json")
    let pageURL = output.appendingPathComponent("review.html")
    for url in labelsPath == nil ? [draftURL, pageURL] : [pageURL]
    where !force && FileManager.default.fileExists(atPath: url.path) {
        fail("\(url.path) already exists; pass --force to replace it.")
    }
    do {
        let review = try StrokeReview(session: session)
        let draft = FixtureLabelsFile.draft(sport: review.sport, labels: review.draft)
        let start = labelsPath.map(readLabels) ?? draft
        if start.sport != review.sport {
            fail("The labels are for \(start.sport.rawValue), not \(review.sport.rawValue).")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if labelsPath == nil { try draft.encoded().write(to: draftURL) }
        let page = try StrokeReviewPage.html(review: review, labels: start, reviewKey: UUID().uuidString.lowercased())
        try Data(page.utf8).write(to: pageURL)
        let counted = review.candidates.filter(\.counted).count
        print(
            """
            Recording  \(review.sport.rawValue), \(Int(review.duration.rounded())) s
            Candidates \(review.candidates.count) strokes (\(counted) counted by session detail)
            """)
        if labelsPath == nil { print("Draft      \(draftURL.path)  (unreviewed, not ground truth)") }
        print("Review     \(pageURL.path)")
    } catch {
        fail("Could not draft labels: \(error)")
    }
}

func score(_ arguments: [String]) -> Never {
    guard arguments.count == 2, !arguments.contains(where: { $0.hasPrefix("-") }) else { fail(usage, 2) }
    let session = readPaddling(arguments[0])
    let file = readLabels(arguments[1])
    if file.source == FixtureLabelsFile.draftSource {
        print("Note: these labels are an unreviewed draft, so this scores the detector against itself.\n")
    }
    guard let labels = file.strokeLabels else { fail("The labels have no truth.strokeTimes.") }
    let problems = labels.problems(duration: max(session.duration, session.motion.last?.t ?? 0))
    if !problems.isEmpty { fail("The labels have problems: " + problems.joined(separator: "; ")) }
    let result: StrokeScore
    do {
        result = try StrokeScore(labels: labels, session: session)
    } catch {
        fail("Could not analyze the recording: \(error)")
    }
    func spm(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }
    let countError = result.countError.map { String(format: "%+.1f %%", 100 * $0) } ?? "–"
    let rateError = result.rateError.map { String(format: "%+.1f SPM", $0) } ?? "–"
    print(
        """
                    Labels   App (session detail)  Error        PLAN §5
        Strokes     \(String(result.truthCount).padding(toLength: 8, withPad: " ", startingAt: 0)) \
        \(String(result.appCount).padding(toLength: 21, withPad: " ", startingAt: 0)) \
        \(countError.padding(toLength: 12, withPad: " ", startingAt: 0)) \(result.countPasses ? "pass" : "FAIL") (±3 %)
        Rate (SPM)  \(spm(result.truthRate).padding(toLength: 8, withPad: " ", startingAt: 0)) \
        \(spm(result.appRate).padding(toLength: 21, withPad: " ", startingAt: 0)) \
        \(rateError.padding(toLength: 12, withPad: " ", startingAt: 0)) \(result.ratePasses ? "pass" : "FAIL") (±2 SPM)

        Per stroke (within 0.45 × the stroke interval, at most \(StrokeScore.matchWindow) s): \(result.matched) matched, \(result.missed) missed, \
        \(result.extra) extra (\(result.extraInExcluded) in excluded segments)
        """)
    if file.source == FixtureLabelsFile.draftSource {
        // Never a pass: a draft is the detector's own output, not ground truth.
        print("\nNot a result: review the labels and export them first.")
        exit(3)
    }
    exit(result.countPasses && result.ratePasses ? 0 : 1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--help") {
    print(usage, terminator: "")
    exit(arguments.isEmpty ? 2 : 0)
}
switch arguments[0] {
case "draft": draft(Array(arguments.dropFirst()))
case "score": score(Array(arguments.dropFirst()))
default: fail(usage, 2)
}
