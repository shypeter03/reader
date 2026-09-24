//
//  KokoroProcessMemory.swift
//  Reader
//
//  进程真实驻留量。`MemoryProbe` 读的是 MLX allocator 的计数器，
//  Kokoro 走 ONNX Runtime、不经过 MLX，用它会恒等于 0MB——所以另开一个读数，
//  不改 MemoryProbe 本身。
//

import Foundation

enum KokoroProcessMemory {

    /// 与 Xcode Memory Gauge 同一口径（phys_footprint），单位 MB。取不到返回 -1。
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ints in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ints, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// 热档位。Kokoro 是纯 CPU 的持续满载负载，一句接一句合成最容易把 SoC 推进
    /// .fair/.serious，那时频率被系统压下去、RTF 直接翻倍——这跟输入长短无关。
    /// 日志里必须带上它，否则「后面几句变慢」没法归因。
    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常"
        case .fair: return "偏热"
        case .serious: return "严重降频"
        case .critical: return "临界降频"
        @unknown default: return "未知"
        }
    }
}
