import Foundation
import AVFoundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: export-alpha <input.mov> <output.mov>")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

let asset = AVAsset(url: inputURL)
let semaphore = DispatchSemaphore(value: 0)

if FileManager.default.fileExists(atPath: outputURL.path) {
    try? FileManager.default.removeItem(at: outputURL)
}

guard let session = AVAssetExportSession(
    asset: asset,
    presetName: AVAssetExportPresetHEVCHighestQualityWithAlpha
) else {
    fail("AVAssetExportSession could not create the HEVC-with-alpha export session")
}

session.outputURL = outputURL
session.outputFileType = .mov
session.shouldOptimizeForNetworkUse = false

session.exportAsynchronously {
    if let error = session.error {
        FileHandle.standardError.write(Data(("export failed: \(error)\n").utf8))
    }
    semaphore.signal()
}

semaphore.wait()

switch session.status {
case .completed:
    guard FileManager.default.fileExists(atPath: outputURL.path) else {
        fail("export reported success but output file is missing")
    }
    print(outputURL.path)
case .failed, .cancelled:
    fail("HEVC-with-alpha export did not complete: \(session.status.rawValue)")
default:
    fail("HEVC-with-alpha export ended in unexpected status: \(session.status.rawValue)")
}
