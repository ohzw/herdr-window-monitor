// The window list for the picker, optionally with a still thumbnail of each
// window: one ScreenCaptureKit screenshot per window, scaled down and written
// as PNG. No stream is started and nothing stays running.
import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Accelerate

struct ListOptions {
    var thumbnails: String?
    var thumbEdge = 480
    var excludePID: Int32 = 0

    static func parse(_ args: ArraySlice<String>) -> ListOptions {
        var o = ListOptions()
        var it = args.makeIterator()
        func next(_ name: String) -> String {
            guard let v = it.next() else { die("missing value for \(name)") }
            return v
        }
        while let a = it.next() {
            switch a {
            case "--thumbnails": o.thumbnails = next(a)
            case "--thumb-edge": o.thumbEdge = Int(next(a)) ?? bad("bad --thumb-edge")
            case "--exclude-pid": o.excludePID = Int32(next(a)) ?? bad("bad --exclude-pid")
            default: die("unknown argument \(a)")
            }
        }
        guard (16...4096).contains(o.thumbEdge) else { die("invalid --thumb-edge") }
        return o
    }
}

struct ThumbnailFailed: Error {}

/// Processes started from one executable path interrupt each other's
/// ScreenCaptureKit connections; two listings at once can hang for good. So
/// listings take turns on a lock next to the executable, held until exit, and
/// give up after `deadline` seconds in all.
func serializeListing(deadline: Double) {
    DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
        FileHandle.standardError.write("window-monitor-helper: listing windows timed out\n".data(using: .utf8)!)
        _exit(2)
    }
    let path = (Bundle.main.executablePath ?? CommandLine.arguments[0]) + ".lock"
    let fd = open(path, O_RDWR | O_CREAT, 0o600)
    guard fd >= 0 else { die("cannot open \(path)") }
    while flock(fd, LOCK_EX) != 0 {
        guard errno == EINTR else { die("cannot lock \(path)") }
    }
}

func listWindows(_ o: ListOptions) async throws -> [[String: Any]] {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let windows = content.windows.filter {
        $0.windowLayer == 0 && $0.frame.width >= 80 && $0.frame.height >= 60
            && (o.excludePID == 0 || $0.owningApplication?.processID != o.excludePID)
    }
    var files: [CGWindowID: String] = [:]
    if let directory = o.thumbnails {
        // The folder must exist: the caller deletes it to discard a listing
        // still running, and nothing here may bring it back.
        files = await withTaskGroup(of: (CGWindowID, String?).self) { group in
            for window in windows {
                group.addTask {
                    // A window that can't be captured (or never answers) just has no thumbnail.
                    let name = try? await withTimeout(3) {
                        try await writeThumbnail(window, directory: directory, edge: o.thumbEdge)
                    }
                    return (window.windowID, name)
                }
            }
            var out: [CGWindowID: String] = [:]
            for await (id, name) in group { if let name { out[id] = name } }
            return out
        }
    }
    return windows.map { w in
        var row: [String: Any] = [
            "id": w.windowID, "pid": w.owningApplication?.processID ?? 0,
            "app": w.owningApplication?.applicationName ?? "",
            "title": w.title ?? "", "width": w.frame.width, "height": w.frame.height,
        ]
        if let file = files[w.windowID] { row["thumbnail"] = file }
        return row
    }
}

/// Writes thumb-<window id>.png into directory and returns its file name.
func writeThumbnail(_ window: SCWindow, directory: String, edge: Int) async throws -> String {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let (width, height) = fitSize(window.frame, scale: CGFloat(filter.pointPixelScale), maxEdge: edge)
    let config = SCStreamConfiguration()
    config.width = width; config.height = height
    config.scalesToFit = true
    config.preservesAspectRatio = true
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = false
    config.capturesAudio = false
    let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
    guard let pb = CMSampleBufferGetImageBuffer(sample) else { throw ThumbnailFailed() }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb), w >= 2, h >= 2 else { throw ThumbnailFailed() }
    var rgb = [UInt8](repeating: 0, count: w * h * 3)
    rgb.withUnsafeMutableBytes { dst in
        var s = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 3)
        vImageConvert_BGRA8888toRGB888(&s, &d, vImage_Flags(kvImageNoFlags))
    }
    var png: [UInt8] = []
    guard rgb.withUnsafeBytes({ PNGEncoder().encode(rgb: $0, width: w, height: h, into: &png) }) else { throw ThumbnailFailed() }
    let name = "thumb-\(window.windowID).png"
    try Data(png).write(to: URL(fileURLWithPath: "\(directory)/\(name)"), options: .atomic)
    return name
}
