import Darwin
import Foundation

/// The process's `phys_footprint`, the number Jetsam judges by (DEBUG diagnostics, D§8).
/// Jetsam is the iOS service that stops an app that uses too much memory. `ImagePreprocessor` and the
/// viewer log this number around large decodes. It returns 0 if the kernel call fails.
enum MemoryFootprint {
  static func current() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    // `task_info` is a C call that fills a buffer of 32-bit words; the pointer cast gives it `info` as one.
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
