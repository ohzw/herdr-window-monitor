import Foundation
import Darwin

final class StageMetrics {
    enum Stage: String, CaseIterable {
        case pngScanlines
        case zlib
        case pngChunksCRC
        case imageFileWrite
        case rename
        case metadataPublish
        case hash
        case colorConvert
    }

    private struct Totals {
        var count: UInt64 = 0
        var elapsedWallNanoseconds: UInt64 = 0
        var threadCPUNanoseconds: UInt64 = 0
    }

    private let lock = NSLock()
    private var totals: [Stage: Totals] = Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, Totals()) })

    @discardableResult
    func measure<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = threadCPUTimeNanoseconds()
        defer {
            let wall = DispatchTime.now().uptimeNanoseconds &- wallStart
            let cpu = threadCPUTimeNanoseconds() &- cpuStart
            lock.lock()
            var value = totals[stage]!
            value.count &+= 1
            value.elapsedWallNanoseconds &+= wall
            value.threadCPUNanoseconds &+= cpu
            totals[stage] = value
            lock.unlock()
        }
        return try body()
    }

    func snapshot() -> [String: Any] {
        lock.lock()
        let current = totals
        lock.unlock()

        var result: [String: Any] = [:]
        for stage in Stage.allCases {
            let value = current[stage]!
            result[stage.rawValue] = [
                "count": value.count,
                "elapsedWallMs": Double(value.elapsedWallNanoseconds) / 1_000_000,
                "threadCPUms": Double(value.threadCPUNanoseconds) / 1_000_000
            ]
        }
        return result
    }

    private func threadCPUTimeNanoseconds() -> UInt64 {
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0 else { return 0 }
        return UInt64(time.tv_sec) &* 1_000_000_000 &+ UInt64(time.tv_nsec)
    }
}
