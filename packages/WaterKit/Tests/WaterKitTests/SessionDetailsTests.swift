import Foundation
import Testing

@testable import WaterKit

struct SessionDetailsTests {
    @Test func normalizesWhatWasTyped() {
        let details = SessionDetails(name: "  Evening\nrace \n", notes: "\n  Gusty at the mark.\n\nLost a batten.  \n")
        #expect(details.name == "Evening race")
        #expect(details.notes == "Gusty at the mark.\n\nLost a batten.")
        #expect(SessionDetails(name: " \n ", notes: "\t").isEmpty)
    }

    @Test func cutsNameAndNotesToTheirLimits() {
        let details = SessionDetails(
            name: String(repeating: "é", count: 150), notes: String(repeating: "🌊", count: 12_000))
        #expect(details.name.count == SessionDetails.maxNameLength)
        #expect(details.notes.count == SessionDetails.maxNotesLength)
        // A cut that ends in spaces doesn't leave them behind.
        let spaced = SessionDetails(name: String(repeating: "a", count: 99) + "  b")
        #expect(spaced.name == String(repeating: "a", count: 99))
    }

    @Test func savesLoadsAndRemoves() throws {
        let folder = try TempFolder()
        let store = SessionDetailsStore(directory: folder.url.appendingPathComponent("Details"))
        let id = UUID()
        #expect(try store.load(sessionId: id) == nil)

        let details = SessionDetails(name: "Evening race", notes: "Gusty")
        try store.save(details, sessionId: id)
        #expect(try store.load(sessionId: id) == details)
        let file = folder.url.appendingPathComponent("Details/\(id.uuidString.lowercased()).json")
        #expect(
            try String(decoding: Data(contentsOf: file), as: UTF8.self)
                == #"{"name":"Evening race","notes":"Gusty","version":1}"#)

        // A name alone leaves notes out of the file.
        try store.save(SessionDetails(name: "Evening race"), sessionId: id)
        #expect(try String(decoding: Data(contentsOf: file), as: UTF8.self) == #"{"name":"Evening race","version":1}"#)

        // Clearing both removes the file; removing again is safe.
        try store.save(SessionDetails(), sessionId: id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try store.remove(sessionId: id)
        #expect(try store.load(sessionId: id) == nil)
    }

    @Test func readsAFileWithUnknownFieldsAndNormalizesIt() throws {
        let folder = try TempFolder()
        let id = UUID()
        try folder.write(
            id.uuidString.lowercased() + ".json",
            Data(#"{"version":1,"name":" Two\nlines ","notes":"","color":"blue"}"#.utf8))
        let store = SessionDetailsStore(directory: folder.url)
        #expect(try store.load(sessionId: id) == SessionDetails(name: "Two lines"))
    }

    @Test func emptyFileContentsReadAsNoDetails() throws {
        let folder = try TempFolder()
        let id = UUID()
        try folder.write(id.uuidString.lowercased() + ".json", Data(#"{"version":1}"#.utf8))
        #expect(try SessionDetailsStore(directory: folder.url).load(sessionId: id) == nil)
    }

    @Test func unknownVersionIsReportedAndItsBytesArePreserved() throws {
        let folder = try TempFolder()
        let id = UUID()
        let name = id.uuidString.lowercased() + ".json"
        let data = Data(#"{"version":2,"title":"Evening race"}"#.utf8)
        try folder.write(name, data)
        let store = SessionDetailsStore(directory: folder.url)
        #expect(throws: SessionDetailsStore.Error.unsupportedVersion(2)) { try store.load(sessionId: id) }
        #expect(try Data(contentsOf: folder.url.appendingPathComponent(name)) == data)
    }
}
