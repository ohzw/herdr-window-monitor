// window-monitor-helper: capture one macOS window with ScreenCaptureKit and
// publish it as PNG files for the Herdr window-monitor mod. Display only: no
// audio, no cursor, no input, no network.
//
// Latest frame wins, unchanged frames are neither converted nor written, and
// buffers are reused. The helper belongs to one mod copy: it runs only while
// that copy keeps refreshing its control file and its Herdr window is visible.
import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Accelerate
import Darwin

// MARK: options

let usage = """
usage: window-monitor-helper --window-id N --png-dir DIR --control FILE [--stats FILE]
                             [--fps 2] [--max-edge 1280] [--publish-delay-ms 0..500]
       window-monitor-helper --list-windows [--thumbnails DIR] [--thumb-edge 480]
       window-monitor-helper --gui-windows-for-pid PID
       window-monitor-helper --permission | --request-permission
--thumbnails writes one PNG per listed window into the existing folder DIR
(thumb-<id>.png, named by the row's "thumbnail" field); windows that could not
be captured have none.
control FILE lines: state=run|pause|stop, gui_pid=N, gui_window=N, and optionally
fps=N and publish_delay_ms=N, which replace --fps and --publish-delay-ms while running.
The controller must refresh FILE at least every 10 seconds; the helper also
exits when gui_pid exits. On exit it deletes the PNGs and metadata it wrote.
"""

struct Options {
    var windowID: UInt32 = 0
    var fps: Double = 2
    var maxEdge = 1280
    var control = ""
    var stats: String?
    var pngDirectory = ""
    var publishDelayMs = 0

    static func parse() -> Options {
        var o = Options()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        func next(_ name: String) -> String {
            guard let v = it.next() else { die("missing value for \(name)") }
            return v
        }
        while let a = it.next() {
            switch a {
            case "--window-id": o.windowID = UInt32(next(a)) ?? bad("bad --window-id")
            case "--fps": o.fps = Double(next(a)) ?? bad("bad --fps")
            case "--max-edge": o.maxEdge = Int(next(a)) ?? bad("bad --max-edge")
            case "--control": o.control = next(a)
            case "--stats": o.stats = next(a)
            case "--png-dir": o.pngDirectory = next(a)
            case "--publish-delay-ms": o.publishDelayMs = Int(next(a)) ?? bad("bad --publish-delay-ms")
            case "-h", "--help": print(usage); exit(0)
            default: die("unknown argument \(a)")
            }
        }
        guard o.windowID > 0, !o.control.isEmpty, !o.pngDirectory.isEmpty else { die("need --window-id, --png-dir and --control") }
        guard o.fps.isFinite, o.fps > 0, o.fps <= 60, (2...4096).contains(o.maxEdge),
              (0...500).contains(o.publishDelayMs) else { die("invalid capture limits") }
        return o
    }
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write("window-monitor-helper: \(msg)\n".data(using: .utf8)!)
    exit(2)
}
func bad<T>(_ msg: String) -> T { die(msg) }

func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

/// Window pixels with the longer edge capped at maxEdge; even sizes.
func fitSize(_ frame: CGRect, scale: CGFloat, maxEdge: Int) -> (Int, Int) {
    var w = Double(frame.width * scale), h = Double(frame.height * scale)
    let aspect = w / max(1, h)
    let cap = Double(maxEdge)
    if max(w, h) > cap { if w >= h { w = cap; h = cap / aspect } else { h = cap; w = cap * aspect } }
    return (max(2, Int(w.rounded()) & ~1), max(2, Int(h.rounded()) & ~1))
}

struct TimedOut: LocalizedError { var errorDescription: String? { "timed out" } }

/// Runs its closure at most once, from whichever caller gets there first.
final class Once: @unchecked Sendable {
    let lock = NSLock()
    var done = false
    func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
}

/// Runs an async call that may never return (ScreenCaptureKit sometimes doesn't
/// for an interrupted stream) and gives up after `seconds`. The call itself
/// can't be cancelled; it is only abandoned.
func withTimeout<T>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        Task {
            do { let value = try await body(); once.run { c.resume(returning: value) } }
            catch { once.run { c.resume(throwing: error) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.run { c.resume(throwing: TimedOut()) } }
    }
}

// MARK: stats

final class Stats {
    let lock = NSLock()
    let start = now()
    let stages = StageMetrics()
    var running = false
    var exitReason: String?
    var callbacks = 0
    var statusCounts: [String: Int] = [:]
    var duplicates = 0        // complete frames whose pixels matched the last one written
    var converted = 0
    var sent = 0
    var rawBytes = 0          // RGB pixels before PNG compression
    var outBytes = 0          // PNG bytes written
    var convertSec = 0.0, compressSec = 0.0
    var reconfigs = 0
    var pauses = 0, resumes = 0
    var lastSize = ""
    var events: [String] = []

    func with(_ f: (Stats) -> Void) { lock.lock(); f(self); lock.unlock() }
    func event(_ s: String) { with { $0.events.append(String(format: "%.2f %@", now() - start, s)); if $0.events.count > 200 { $0.events.removeFirst() } } }

    func json() -> Data {
        lock.lock(); defer { lock.unlock() }
        var rusage = rusage(); getrusage(RUSAGE_SELF, &rusage)
        let cpu = Double(rusage.ru_utime.tv_sec + rusage.ru_stime.tv_sec) + Double(rusage.ru_utime.tv_usec + rusage.ru_stime.tv_usec) / 1e6
        let d: [String: Any] = [
            "elapsed_s": now() - start, "callbacks": callbacks, "status": statusCounts,
            "duplicates": duplicates, "converted": converted, "sent": sent,
            "raw_bytes": rawBytes, "out_bytes": outBytes,
            "convert_ms": convertSec * 1000, "compress_ms": compressSec * 1000,
            "reconfigs": reconfigs, "pauses": pauses, "resumes": resumes, "size": lastSize,
            "self_cpu_s": cpu, "max_rss_bytes": rusage.ru_maxrss, "events": events,
            "pid": getpid(), "running": running, "exit_reason": exitReason ?? "",
            "processing_stages": stages.snapshot(),
        ]
        return try! JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])
    }
}

/// Recycles PNG buffer capacity between frames.
final class Pool {
    private let lock = NSLock()
    private var free: [[UInt8]] = []
    func take() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        var b = free.popLast() ?? []
        b.removeAll(keepingCapacity: true)
        return b
    }
    func give(_ b: [UInt8]) {
        lock.lock(); if free.count < 4 { free.append(b) }; lock.unlock()
    }
}

// MARK: capture

// Frame state belongs to capQueue. Stream settings (size, frame rate, wait)
// belong to cfgQueue: capQueue can be busy for seconds (each image may wait
// up to 500 ms before it is announced), and a settings change must not queue
// behind those images. Lifecycle state belongs to ctlQueue, which serializes
// async start/stop using a semaphore. Stats lock their own state; the stream
// reference is installed before callbacks.
final class Monitor: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let opt: Options
    let stats = Stats()
    let pool = Pool()
    let capQueue = DispatchQueue(label: "wm.capture", qos: .utility)
    let cfgQueue = DispatchQueue(label: "wm.config")
    let ctlQueue = DispatchQueue(label: "wm.control")

    var stream: SCStream?
    var lastHash: UInt64 = 0
    var running = false
    var pauseReasons: Set<String> = ["control"]
    var scratch: [UInt8] = []     // RGB pixels
    // cfgQueue
    var width = 0, height = 0
    var fps: Double
    var publishDelayMs: Int
    var resizing = false          // window lookup for a resize in flight
    var configUpdating = false    // updateConfiguration in flight
    var configDirty = false       // size or fps changed during that update
    // ctlQueue
    var guiSource: DispatchSourceProcess?
    var dirSource: DispatchSourceFileSystemObject?
    var visibilityTimer: DispatchSourceTimer?
    var watchedGUI: Int32 = 0
    var watchedWindow: CGWindowID = 0
    lazy var pngEncoder = PNGEncoder(metrics: stats.stages)
    var pngFiles: PNGFiles?

    init(opt: Options) {
        self.opt = opt
        fps = opt.fps
        publishDelayMs = opt.publishDelayMs
    }

    func targetSize(for frame: CGRect, scale: CGFloat) -> (Int, Int) {
        fitSize(frame, scale: scale, maxEdge: opt.maxEdge)
    }

    func findWindow() async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if let w = content.windows.first(where: { $0.windowID == opt.windowID }) { return w }
        throw NSError(domain: "window-monitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "window not found"])
    }

    func makeConfig() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = width; c.height = height
        c.scalesToFit = true
        c.preservesAspectRatio = true
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.minimumFrameInterval = CMTime(seconds: 1 / fps, preferredTimescale: 600)
        c.queueDepth = 3
        c.showsCursor = false
        c.capturesAudio = false
        return c
    }

    /// Prepares the stream paused; the control file decides when it runs.
    func start() async throws {
        pngFiles = try PNGFiles(directory: opt.pngDirectory, metrics: stats.stages)
        let s = try await makeStream()
        capQueue.sync { stream = s }
        stats.event("waiting for controller")
    }

    func makeStream() async throws -> SCStream {
        let window = try await findWindow()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let frame = window.frame
        let scale = CGFloat(filter.pointPixelScale)
        let (config, size) = cfgQueue.sync {
            (width, height) = targetSize(for: frame, scale: scale)
            return (makeConfig(), "\(width)x\(height)")
        }
        stats.with { $0.lastSize = size }
        stats.event("window \(window.windowID) frame \(window.frame) -> \(size)")
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: capQueue)
        return s
    }

    /// Streams the system ended while their window still exists (ctlQueue).
    /// The error can arrive before the stream is even installed, so remember
    /// them by identity; the next resume builds a new stream.
    var brokenStreams = Set<ObjectIdentifier>()

    func isBroken(_ s: SCStream) -> Bool { brokenStreams.contains(ObjectIdentifier(s)) }

    /// Pause/resume from the control file, the GUI process or its visibility.
    func setPaused(_ reason: String, _ on: Bool) {
        ctlQueue.async {
            if on { self.pauseReasons.insert(reason) } else { self.pauseReasons.remove(reason) }
            let want = self.pauseReasons.isEmpty
            guard want != self.running, let current = self.stream else { return }
            let broken = self.isBroken(current)
            let sema = DispatchSemaphore(value: 0)
            Task {
                do {
                    if want {
                        // A stream the system interrupted may never start; give
                        // it a few seconds, then build a fresh one once.
                        var s = current
                        for attempt in 0..<2 {
                            if broken || attempt > 0 {
                                s = try await self.makeStream()
                                self.capQueue.sync { self.stream = s }
                                self.stats.event("stream rebuilt")
                            }
                            self.capQueue.sync { self.lastHash = 0 }
                            do {
                                let starting = s
                                try await withTimeout(3) { try await starting.startCapture() }
                                break
                            } catch where attempt == 0 {
                                self.stats.event("start failed (\(error.localizedDescription)); rebuilding")
                            }
                        }
                    } else if !broken {
                        try await current.stopCapture()
                        self.capQueue.sync {}
                    }
                    self.running = want
                    self.stats.with {
                        $0.running = want
                        if want { $0.resumes += 1 } else { $0.pauses += 1 }
                    }
                    self.stats.event(want ? "resumed" : "paused (\(self.pauseReasons.sorted().joined(separator: ",")))")
                } catch {
                    self.stats.event("start/stop error \(error.localizedDescription)")
                }
                sema.signal()
            }
            // Never let a stuck ScreenCaptureKit call block the lease checks.
            if sema.wait(timeout: .now() + 15) == .timedOut {
                self.finish(message: "screen capture did not respond", code: 4)
            }
        }
    }

    func watchControl() {
        let path = opt.control
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { finish(message: "control folder missing", code: 1) }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: ctlQueue)
        src.setEventHandler { [weak self] in self?.readControl() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
        let timer = DispatchSource.makeTimerSource(queue: ctlQueue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Lease: a controller that stopped refreshing the file is gone.
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            if modified == nil || Date().timeIntervalSince(modified!) > 10 {
                self.finish(message: "controller lease expired", code: 0)
            }
            // ScreenCaptureKit doesn't always report a closed window (seen on
            // a stream rebuilt after an interruption), so ask directly.
            let target = CGWindowListCopyWindowInfo(.optionIncludingWindow, self.opt.windowID) as? [[String: Any]] ?? []
            if !target.contains(where: { ($0[kCGWindowNumber as String] as? UInt32) == self.opt.windowID }) {
                self.finish(message: "target window is gone: closed", code: 3)
            }
            self.checkGUIVisibility()
        }
        timer.resume()
        visibilityTimer = timer
        ctlQueue.async { self.readControl() }
    }

    func readControl() {
        guard let text = try? String(contentsOfFile: opt.control, encoding: .utf8) else {
            setPaused("control", true)
            return
        }
        var state = "pause"
        var gui: Int32 = 0
        var guiWindow: CGWindowID = 0
        var fps: Double?
        var delayMs: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            if kv[0] == "state" { state = kv[1] }
            if kv[0] == "gui_pid" { gui = Int32(kv[1]) ?? 0 }
            if kv[0] == "gui_window" { guiWindow = UInt32(kv[1]) ?? 0 }
            if kv[0] == "fps" { fps = Double(kv[1]).flatMap { $0.isFinite && $0 > 0 && $0 <= 60 ? $0 : nil } }
            if kv[0] == "publish_delay_ms" { delayMs = Int(kv[1]).flatMap { (0...500).contains($0) ? $0 : nil } }
        }
        if state == "stop" { finish(message: nil, code: 0) }
        applyLimits(fps: fps, publishDelayMs: delayMs)
        if gui != watchedGUI {
            watchedGUI = gui
            guiSource?.cancel(); guiSource = nil
            guard gui > 0, kill(gui, 0) == 0 else { finish(message: "controller GUI exited", code: 0) }
            let src = DispatchSource.makeProcessSource(identifier: gui, eventMask: .exit, queue: ctlQueue)
            src.setEventHandler { [weak self] in
                guard let self, self.watchedGUI == gui else { return }
                self.finish(message: "controller GUI exited", code: 0)
            }
            src.resume()
            guiSource = src
        }
        watchedWindow = guiWindow
        checkGUIVisibility()
        setPaused("control", state != "run" || watchedGUI <= 0)
    }

    // A background window may still be visible, so ask about the exact Herdr
    // window: minimized or on another Space means hidden.
    func checkGUIVisibility() {
        guard watchedWindow > 0,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, watchedWindow) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == watchedWindow }),
              (info[kCGWindowOwnerPID as String] as? Int32) == watchedGUI else {
            setPaused("gui-hidden", true)
            return
        }
        setPaused("gui-hidden", !(info[kCGWindowIsOnscreen as String] as? Bool ?? false))
    }

    /// Takes new limits from the control file. The wait applies from the next
    /// image; the frame rate updates the running (or paused) stream.
    func applyLimits(fps newFPS: Double?, publishDelayMs newDelay: Int?) {
        cfgQueue.async {
            if let newDelay, newDelay != self.publishDelayMs {
                self.publishDelayMs = newDelay
                self.stats.event("publish delay \(newDelay) ms")
            }
            if let newFPS, newFPS != self.fps {
                self.fps = newFPS
                self.pushConfig()
            }
        }
    }

    /// Re-read the window frame and update the stream size (window resized).
    func reconfigure() {
        cfgQueue.async {
            guard !self.resizing, !self.configUpdating, self.stream != nil else { return }
            self.resizing = true
            Task {
                guard let w = try? await self.findWindow() else {
                    self.cfgQueue.async { self.resizing = false }
                    return
                }
                let frame = w.frame
                let scale = CGFloat(SCContentFilter(desktopIndependentWindow: w).pointPixelScale)
                self.cfgQueue.async {
                    self.resizing = false
                    let (nw, nh) = self.targetSize(for: frame, scale: scale)
                    guard nw != self.width || nh != self.height else { return }
                    self.width = nw; self.height = nh
                    self.stats.event("window resized to \(frame)")
                    self.pushConfig()
                }
            }
        }
    }

    /// Sends the current size and frame rate to the stream (cfgQueue). Updates
    /// never overlap; a change made during one is sent once it finishes. A
    /// stream rebuilt meanwhile already starts from the current values.
    func pushConfig() {
        guard let current = stream else { return }
        guard !configUpdating else { configDirty = true; return }
        configUpdating = true
        let config = makeConfig()
        let size = "\(width)x\(height)", fps = self.fps
        Task {
            do {
                try await current.updateConfiguration(config)
                self.stats.with { $0.reconfigs += 1; $0.lastSize = size }
                self.stats.event("configured \(size) at \(fps) fps")
            } catch { self.stats.event("configure error \(error.localizedDescription)") }
            self.cfgQueue.async {
                self.configUpdating = false
                if self.configDirty { self.configDirty = false; self.pushConfig() }
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        stats.with { $0.callbacks += 1 }
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let name: String
        switch status {
        case .complete: name = "complete"
        case .idle: name = "idle"
        case .blank: name = "blank"
        case .suspended: name = "suspended"
        case .started: name = "started"
        case .stopped: name = "stopped"
        @unknown default: name = "other\(raw)"
        }
        stats.with { $0.statusCounts[name, default: 0] += 1 }
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { return }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let bw = CVPixelBufferGetWidth(pb), bh = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        // Crop to the window content (preservesAspectRatio letterboxes after a resize).
        var crop = CGRect(x: 0, y: 0, width: bw, height: bh)
        if let rd = info[.contentRect], let r = CGRect(dictionaryRepresentation: rd as! CFDictionary) {
            let sf = (info[.scaleFactor] as? Double) ?? 1
            let px = CGRect(x: r.minX * sf, y: r.minY * sf, width: r.width * sf, height: r.height * sf).integral
            let clipped = px.intersection(crop)
            if !clipped.isNull, clipped.width >= 2, clipped.height >= 2 { crop = clipped }
            let bufAspect = Double(bw) / Double(bh), contentAspect = Double(r.width) / Double(max(1, r.height))
            if abs(bufAspect / contentAspect - 1) > 0.02 { reconfigure() }
        }
        let cx = Int(crop.minX), cy = Int(crop.minY), cw = Int(crop.width), ch = Int(crop.height)
        let origin = base + cy * bpr + cx * 4

        // Skip pixel-identical frames before any conversion.
        let h = stats.stages.measure(.hash) {
            var hash: UInt64 = 0xcbf29ce484222325 ^ UInt64(cw << 20 | ch)
            for y in 0..<ch {
                let row = (origin + y * bpr).assumingMemoryBound(to: UInt32.self)
                for i in 0..<cw { hash = (hash ^ UInt64(row[i])) &* 0x100000001b3 }
            }
            return hash
        }
        if h == lastHash { stats.with { $0.duplicates += 1 }; return }
        lastHash = h

        let t0 = now()
        let need = cw * ch * 3
        if scratch.count < need { scratch = [UInt8](repeating: 0, count: need) }
        stats.stages.measure(.colorConvert) {
            scratch.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: origin), height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: bpr)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: cw * 3)
                vImageConvert_BGRA8888toRGB888(&s, &d, vImage_Flags(kvImageNoFlags))
            }
        }
        let t1 = now()
        var png = pool.take()
        let encoded = scratch.withUnsafeBytes {
            pngEncoder.encode(rgb: UnsafeRawBufferPointer(rebasing: $0[..<need]), width: cw, height: ch, into: &png)
        }
        let delay = cfgQueue.sync { Double(publishDelayMs) / 1000 }
        guard encoded, pngFiles!.publish(png, width: cw, height: ch, delay: delay) else {
            finish(message: "PNG publication failed", code: 1)
        }
        stats.with {
            $0.converted += 1; $0.sent += 1; $0.rawBytes += need; $0.outBytes += png.count
            $0.convertSec += t1 - t0; $0.compressSec += now() - t1
        }
        pool.give(png)
    }

    // MARK: SCStreamDelegate

    /// The system also ends streams that were merely interrupted (for example
    /// -3805 when another capture of the same window starts or stops). Exit
    /// only when the window is really gone; otherwise rebuild on next resume.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stats.event("stream stopped: \(error.localizedDescription) (\((error as NSError).code))")
        let ended = ObjectIdentifier(stream)
        Task {
            guard (try? await self.findWindow()) != nil else {
                self.finish(message: "target window is gone: \(error.localizedDescription)", code: 3)
            }
            self.ctlQueue.async {
                self.brokenStreams.insert(ended)
                guard let current = self.stream, ObjectIdentifier(current) == ended, self.running else { return }
                self.running = false
                self.stats.with { $0.running = false }
                self.setPaused("stream", false) // resume now if wanted
            }
        }
    }

    func dumpStats() {
        guard let p = opt.stats else { return }
        try? stats.json().write(to: URL(fileURLWithPath: p), options: .atomic)
    }

    func finish(message: String?, code: Int32) -> Never {
        stats.with { $0.running = false; $0.exitReason = message }
        dumpStats()
        // The mod shows these images only while this helper runs. Stats stay
        // so the mod can still read why the helper stopped.
        pngFiles?.removeOwnedBeforeExit()
        if let message { FileHandle.standardError.write((message + "\n").data(using: .utf8)!) }
        // _exit, not exit: exit() runs framework teardown that can deadlock
        // when called from a Swift concurrency thread with a stream active
        // (seen when the watched window closed). All our cleanup is done.
        fflush(nil)
        _exit(code)
    }
}

// MARK: main

func printJSON(_ value: Any) -> Never {
    print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}

@main
enum HelperMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        // Establish a WindowServer connection before calling ScreenCaptureKit.
        _ = CGMainDisplayID()
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--permission"] {
            printJSON(["granted": CGPreflightScreenCaptureAccess()])
        }
        if args == ["--request-permission"] {
            // Shows the system prompt (or adds the entry to System Settings).
            printJSON(["granted": CGRequestScreenCaptureAccess()])
        }
        if args.first == "--list-windows" {
            let options = ListOptions.parse(args.dropFirst())
            serializeListing(deadline: 15)
            Task {
                do {
                    guard CGPreflightScreenCaptureAccess() else { die("screen recording permission required") }
                    printJSON(try await listWindows(options))
                } catch { die(error.localizedDescription) }
            }
            dispatchMain()
        }
        if args.count == 2, args[0] == "--gui-windows-for-pid", let pid = Int32(args[1]) {
            let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            printJSON(list.compactMap { info -> UInt32? in
                guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      (info[kCGWindowName as String] as? String) == "Herdr",
                      let bounds = info[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                      rect.width >= 100, rect.height >= 80 else { return nil }
                return info[kCGWindowNumber as String] as? UInt32
            })
        }
        let opt = Options.parse()
        let monitor = Monitor(opt: opt)
        // A closed terminal sends SIGHUP; every exit path removes owned images.
        for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, SIG_IGN) }
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { monitor.finish(message: nil, code: 0) }
            source.resume()
            signalSources.append(source)
        }
        let statsTimer = DispatchSource.makeTimerSource(queue: .main)
        statsTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        statsTimer.setEventHandler { monitor.dumpStats() }
        if opt.stats != nil { statsTimer.resume() }
        Task {
            do {
                try await monitor.start()
                monitor.watchControl()
            } catch {
                monitor.finish(message: "window-monitor-helper: \(error.localizedDescription)", code: 1)
            }
        }
        withExtendedLifetime((monitor, statsTimer, signalSources)) { dispatchMain() }
    }
}
