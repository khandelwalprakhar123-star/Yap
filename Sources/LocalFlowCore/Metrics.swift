import Foundation

/// Timing + memory instrumentation shared by the CLI harness and the app.
public enum Metrics {
    /// Physical memory footprint of this process in bytes (same figure Xcode's
    /// memory gauge and Activity Monitor's "Memory" column report).
    public static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    public static func formatMS(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: "%.2f s", seconds)
                     : String(format: "%.0f ms", seconds * 1000)
    }
}

/// Measures one pipeline stage: wall-clock time plus the process footprint after it ran.
public struct StageReport {
    public let name: String
    public let seconds: Double
    public let footprintAfter: UInt64

    public init(name: String, seconds: Double, footprintAfter: UInt64) {
        self.name = name
        self.seconds = seconds
        self.footprintAfter = footprintAfter
    }
}

public func measureStage<T>(_ name: String, _ body: () async throws -> T) async rethrows -> (T, StageReport) {
    let start = ContinuousClock.now
    let value = try await body()
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    return (value, StageReport(name: name, seconds: seconds,
                               footprintAfter: Metrics.memoryFootprint()))
}
