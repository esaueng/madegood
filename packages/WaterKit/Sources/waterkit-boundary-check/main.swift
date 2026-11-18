import Foundation
import WaterKit

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(status)
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: waterkit-boundary-check <local-pack-file>", status: 2)
}

let source = PackedWaterBoundarySource(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
switch source.validation {
case .success(let manifest):
    print("Valid synthetic boundary pack (format \(manifest.formatVersion), revision \(manifest.revision))")
case .failure(let error):
    fail("Boundary pack rejected (\(error))", status: 1)
}
