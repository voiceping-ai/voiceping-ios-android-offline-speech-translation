import Foundation
import Darwin

/// Lightweight process-level CPU and memory sampling.
/// - CPU%: sum of all thread cpu_usage via task_threads / thread_basic_info
/// - Memory: physical footprint via task_info (same metric as Xcode Instruments)
final class SystemMetrics: Sendable {

    /// Process CPU usage as 0-100+ (can exceed 100 on multi-core).
    func cpuPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadList else { return 0 }
        defer {
            let size = vm_size_t(MemoryLayout<thread_t>.size * Int(threadCount))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), size)
        }

        var totalUsage: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info_data_t()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { raw in
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), raw, &infoCount)
                }
            }
            if kr == KERN_SUCCESS && info.flags & TH_FLAGS_IDLE == 0 {
                totalUsage += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return totalUsage
    }

    /// Process physical memory footprint in MB.
    func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }
}
