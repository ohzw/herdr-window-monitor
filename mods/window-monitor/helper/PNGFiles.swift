// Publishes each frame under a new name (frame-N.png) and then metadata
// (current.json) that names it. The newest three images are kept so the mod
// can keep the previous one it showed underneath the new one while it loads,
// even when it skipped one frame (at high frame rates it reads about as often
// as frames arrive).
//
// delay waits between the PNG's atomic rename and the metadata update. It
// does NOT confirm that Herdr finished loading or invalidating an image (no
// public API reports that); it only moves the announcement later. 0 = at once.
import Foundation
import Darwin

final class PNGFiles {
    let directory: String
    private let metrics: StageMetrics?
    private let lock = NSLock()
    private var frame = 0
    private var retained: [String] = []

    init(directory: String, metrics: StageMetrics? = nil) throws {
        self.directory = directory
        self.metrics = metrics
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private var temporary: String { directory + "/.frame.new" }
    private var metadata: String { directory + "/current.json" }

    func publish(_ bytes: [UInt8], width: Int, height: Int, delay: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let path = directory + "/frame-\(frame).png"
        let success = measure(.imageFileWrite) {
            let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0 else { return false }
            let written = bytes.withUnsafeBytes { data -> Bool in
                var offset = 0
                while offset < data.count {
                    let n = write(fd, data.baseAddress! + offset, data.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            close(fd)
            return written
        }
        guard success, measure(.rename, { rename(temporary, path) == 0 }) else { return false }
        retained.append(path)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let published = measure(.metadataPublish) {
            let metadata: [String: Any] = ["frame": frame, "file": path, "width": width, "height": height]
            do {
                let data = try JSONSerialization.data(withJSONObject: metadata)
                try data.write(to: URL(fileURLWithPath: self.metadata), options: .atomic)
                return true
            } catch { return false }
        }
        guard published else { return false }
        if retained.count > 3 { unlink(retained.removeFirst()) }
        frame += 1
        return true
    }

    /// Deletes every image, the temporary file and the metadata this instance
    /// wrote. Call only immediately before process exit: the lock is kept so no
    /// later publication can recreate a file.
    func removeOwnedBeforeExit() {
        lock.lock()
        for path in retained + [temporary, metadata] { unlink(path) }
    }

    private func measure<T>(_ stage: StageMetrics.Stage, _ body: () throws -> T) rethrows -> T {
        guard let metrics else { return try body() }
        return try metrics.measure(stage, body)
    }
}
