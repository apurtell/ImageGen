import Darwin
import Foundation

/// Low- level diagnostic utility querying Mach task virtual memory statistics.
/// Used by imaging operations to monitor resident memory pressure against system thresholds.
enum MemoryFootprint {
  static func current() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
  }

  static func mb(_ bytes: UInt64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
  }
}
