import Foundation

// ============ 系统状态（模块三） ============

/// 一台机器上「是什么」的那一块：`SYNO.Core.System` v2 `info`。
///
/// 🔴 `up_time` 是 `"11:1:0"` 这种**时长**字符串（不是 Unix 时间戳），
/// 而且**分与秒都不补零** —— 早期记的 `5:27:13` / `10:56:51` 恰好都是两位数，
/// 按定长切会切错。`SystemHealth.uptime` 同型。
struct SystemDevice: Equatable {
    let model: String
    let firmware: String
    let serial: String
    /// 整机温度（`sys_temp`，摄氏度）。
    let temperature: Int
    /// `sys_tempwarn` 或 `temperature_warning` 任一为真 —— 两个字段同进同出，
    /// 合成一个判据给界面。
    let temperatureWarn: Bool
    let cpuFamily: String
    let cpuSeries: String
    let cpuCores: Int
    let cpuClockMHz: Int
    /// 出厂内存（`ram_size`，MB 为单位，取回来已换成字节）。
    let ramBytes: Int64
    /// 开机时长折算的秒数。
    let uptimeSeconds: Int

    /// 开机时刻。**由本机时钟减去开机时长**，不去解析服务端那句 `time`
    /// —— 那句是 NAS 本地时区的墙面时间，本机换个时区就会算歪；而「开机于」
    /// 对用户来说本来就该按他这台的钟走。
    var bootedAt: Date { Date().addingTimeInterval(-Double(uptimeSeconds)) }

    /// 页头副行用：`DSM 7.4.1-90080 Update 1 · 已开机 11 小时`。
    var uptimePhrase: String {
        let hours = uptimeSeconds / 3600
        if hours >= 24 {
            return "已开机 \(hours / 24) 天 \(hours % 24) 小时"
        }
        if hours >= 1 { return "已开机 \(hours) 小时" }
        return "已开机 \(max(1, uptimeSeconds / 60)) 分钟"
    }
}

/// 一张状态卡要的两半：主值 + 单位 + 脚注。四张卡各拼各的，形态统一。
struct SystemStat: Equatable {
    let icon: String
    let label: String
    let value: String
    /// 主值后面的小字（`%` / `°C` / `小时`）。空串就是不写。
    let unit: String
    let note: String
    /// 脚注的告警档：温度偏高一类，字转 `warn-ink-strong`。
    let isWarning: Bool

    init(icon: String, label: String, value: String, unit: String = "",
         note: String, isWarning: Bool = false) {
        self.icon = icon
        self.label = label
        self.value = value
        self.unit = unit
        self.note = note
        self.isWarning = isWarning
    }
}

/// 一卷的读写与利用率（`Utilization` 的 `space.volume[]`）。
struct VolumeLoad: Equatable {
    let id: String
    let readBytesPerSec: Int64
    let writeBytesPerSec: Int64
    /// 传输利用率（0–100，盘忙的百分比）。
    let utilization: Int
}

/// 一块盘的读写与利用率（`Utilization` 的 `disk.disk[]`）。
struct DiskLoad: Equatable {
    let id: String
    let readBytesPerSec: Int64
    let writeBytesPerSec: Int64
    let utilization: Int
}

/// 负载那一块：`SYNO.Core.System.Utilization` v1 `get`。
///
/// 🔴 两组数的**单位不一样**，这是这块最容易写错的地方（实测判据见
/// `docs/接口结论.md` 第十节）：
///   · `user_load` / `system_load` / `other_load` 是**百分比** —— 三个加起来
///     就是整机占用（四线程归一）。DSM 自己的「利用率 = 用户 + 系统」也照这个取，
///     `other_load` 是 I/O 等待。
///   · `1min_load` / `5min_load` / `15min_load` 是**平均负载 × 100**，除以 100
///     才是 `uptime` 那个量（取值实测 110–246，一台两核机器上不可能是百分比）。
///     R1600 是 2 核 4 线程：0.28 的利用率对应 1.10 的平均负载，两边对得上。
///   · `read_byte` / `write_byte` 是**字节/秒**（不是累计值，也不是采样间隔量）——
///     限速下载那一轮拿本机测到的速率对过；`network.rx/tx` 同单位。
struct SystemLoad: Equatable {
    let cpuUser: Int
    let cpuSystem: Int
    let cpuIO: Int
    let load1: Double
    let load5: Double
    let load15: Double
    let memoryPercent: Int
    let memoryTotalBytes: Int64
    let memoryAvailableBytes: Int64
    let memoryCachedBytes: Int64
    let volumes: [VolumeLoad]
    let disks: [DiskLoad]

    /// 界面上的「CPU 使用率」＝ 用户 + 系统（DSM 的利用率口径，I/O 等待不算占用）。
    var cpuUsage: Int { cpuUser + cpuSystem }

    func load(for id: String) -> DiskLoad? { disks.first { $0.id == id } }
    func volume(_ id: String) -> VolumeLoad? { volumes.first { $0.id == id } }
}

/// 一块盘「有多大、多热、好不好」：`Storage.CGI.Storage` `load_info` 的 `disks[]`。
///
/// 🔴 这里**没有 `used`** —— 单盘的已用量服务端不给（SHR 之下盘也不是各自独立的
/// 卷），所以原型里「每块盘一条进度条」落不了地，进度条只能给卷。
struct StorageDisk: Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let vendor: String
    let sizeBytes: Int64
    let temperature: Int
    let status: String
    let smartStatus: String
    /// `remain_life` = `{"trustable": true, "value": -1}` —— **`-1` 是「不适用」**，
    /// 界面得先看 `trustable` 再看数，不然会显示「剩余寿命 -1%」（机械盘就是这个形态）。
    let remainLifeTrustable: Bool
    let remainLifePercent: Int

    var isHealthy: Bool { status.lowercased() == "normal" }
}

/// 一卷的容量与状态（`Storage.CGI.Storage` 的 `volumes[]`）。
///
/// 🔴 `size` 里**全是字符串**：`{"total":"17268860907520","used":"13330440351744",…}`。
/// 界面取 `size.total`（15.71 TB），**不是 `total_device`**（16.36 TB，裸容量、
/// 含 RAID 冗余那部分）。
struct StorageVolume: Identifiable, Equatable {
    let id: String
    /// `volumes[].num_id`（1、2……）。界面上叫「存储空间 1」——`volumes[]` 里
    /// **没有 `display_name` 这个键**，拿它拼（DSM 中文把 Volume 叫存储空间）。
    let numID: Int
    let fsType: String
    let raidType: String
    let status: String
    let totalBytes: Int64
    let usedBytes: Int64
    let deviceBytes: Int64

    var name: String { numID > 0 ? "存储空间 \(numID)" : id }

    /// 🔴 拿它去 `Utilization` 的 `space.volume[]` 里找这一卷的读写：
    /// 那边给的是 `display_name` = `"volume1"`，而这边 `id` = `"volume_1"`
    /// —— **中间那个下划线不一样**，按 `id` 直接对是永远对不上的。
    var loadID: String { "volume\(numID)" }

    var usedPercent: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    var freeBytes: Int64 { max(0, totalBytes - usedBytes) }
    var isHealthy: Bool { status.lowercased() == "normal" }
}

/// 磁盘与卷那一块：`Storage.CGI.Storage` v1 `load_info`。
struct SystemStorage: Equatable {
    let volumes: [StorageVolume]
    let disks: [StorageDisk]
}

/// 健康标志：`SYNO.Core.System.Status` v1 `get`。
///
/// 三个键实测都有：`ext_nic_is_incompatible` / `is_system_crashed` / `upgrade_ready`。
/// 只收前两个 —— 升级与否在设置页谈，状态页只管「有没有出事」。
struct SystemHealth: Equatable {
    let crashed: Bool
    let nicIncompatible: Bool

    var isNormal: Bool { !crashed && !nicIncompatible }

    /// 提示条上的话。两条都不写「不是…而是…」那类对举，只陈述发生了什么。
    var warnings: [String] {
        var out: [String] = []
        if crashed { out.append("上次关机不正常：系统崩溃或断电，建议查一次硬盘状态") }
        if nicIncompatible { out.append("有一块扩展网卡不兼容，当前未启用") }
        return out
    }
}

/// 一次刷新的结果。**四块各自可选** —— 三条接口互相独立，掉一条只该少一块，
/// 不该整屏空白（中继链路上这几条的成功率本来就参差，见 `接口结论.md`）。
struct SystemSnapshot: Equatable {
    var device: SystemDevice?
    var load: SystemLoad?
    var storage: SystemStorage?
    var health: SystemHealth?
    /// 没取回来的那几块，各带一句原因。界面按它决定哪张卡显示「没读到」。
    var failures: [String] = []
    var takenAt: Date = Date()

    var isEmpty: Bool {
        device == nil && load == nil && storage == nil && health == nil
    }
}

/// 系统状态的取数层。四条接口一次并发发出去，各解各的。
enum SystemStatusAPI {
    /// 取一次快照。**不抛** —— 逐块 try，坏的那块记进 `failures`；
    /// 四块全坏才由调用方按 `isEmpty` 判成失败。
    static func fetch(_ manager: SessionManager) async -> SystemSnapshot {
        async let deviceTask = captured { try await device(manager) }
        async let loadTask = captured { try await load(manager) }
        async let storageTask = captured { try await storage(manager) }
        async let healthTask = captured { try await health(manager) }

        let (deviceResult, loadResult, storageResult, healthResult) =
            await (deviceTask, loadTask, storageTask, healthTask)

        var snapshot = SystemSnapshot()
        var failures: [String] = []
        snapshot.device = carry(deviceResult, "机器信息", into: &failures)
        snapshot.load = carry(loadResult, "负载", into: &failures)
        snapshot.storage = carry(storageResult, "容量", into: &failures)
        snapshot.health = carry(healthResult, "系统状态", into: &failures)
        snapshot.failures = failures
        return snapshot
    }

    /// 把「可能抛」的那一半收成一个结果值 —— 四块要并发，不能一抛就带走别的。
    private static func captured<T>(
        _ work: @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private static func carry<T>(
        _ result: Result<T, Error>, _ label: String, into failures: inout [String]
    ) -> T? {
        switch result {
        case let .success(value): return value
        case let .failure(error):
            failures.append("\(label)：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 四块

    /// `Core.System` v2 `info`。
    static func device(_ manager: SessionManager) async throws -> SystemDevice {
        let raw = try await manager.call(
            kind: .file, api: "SYNO.Core.System", version: 2, method: "info"
        )
        let data = (raw as? [String: Any]) ?? [:]
        return SystemDevice(
            model: (data["model"] as? String) ?? "",
            firmware: (data["firmware_ver"] as? String) ?? "",
            serial: (data["serial"] as? String) ?? "",
            temperature: Int(number(data["sys_temp"]) ?? 0),
            temperatureWarn: bool(data["sys_tempwarn"]) || bool(data["temperature_warning"]),
            cpuFamily: (data["cpu_family"] as? String) ?? "",
            cpuSeries: (data["cpu_series"] as? String) ?? "",
            cpuCores: Int(number(data["cpu_cores"]) ?? 0),
            cpuClockMHz: Int(number(data["cpu_clock_speed"]) ?? 0),
            // `ram_size` 单位是 MB，换回字节。
            ramBytes: (number(data["ram_size"]) ?? 0) * 1024 * 1024,
            uptimeSeconds: seconds((data["up_time"] as? String) ?? "")
        )
    }

    /// `Core.System.Utilization` v1 `get`（**只有 v1，v2 回 104**）。
    static func load(_ manager: SessionManager) async throws -> SystemLoad {
        let raw = try await manager.call(
            kind: .file, api: "SYNO.Core.System.Utilization", version: 1, method: "get"
        )
        let data = (raw as? [String: Any]) ?? [:]
        let cpu = (data["cpu"] as? [String: Any]) ?? [:]
        let memory = (data["memory"] as? [String: Any]) ?? [:]
        let space = (data["space"] as? [String: Any]) ?? [:]
        let diskBox = (data["disk"] as? [String: Any]) ?? [:]
        let diskRows = (diskBox["disk"] as? [[String: Any]]) ?? []

        return SystemLoad(
            cpuUser: Int(number(cpu["user_load"]) ?? 0),
            cpuSystem: Int(number(cpu["system_load"]) ?? 0),
            cpuIO: Int(number(cpu["other_load"]) ?? 0),
            // 服务端给的是 ×100 的整数，除以 100 才是平均负载。
            load1: Double(number(cpu["1min_load"]) ?? 0) / 100,
            load5: Double(number(cpu["5min_load"]) ?? 0) / 100,
            load15: Double(number(cpu["15min_load"]) ?? 0) / 100,
            memoryPercent: Int(number(memory["real_usage"]) ?? 0),
            // `memory_size` 是出厂内存、`total_real` 是系统可用的那一部分，都按 KB 给。
            memoryTotalBytes: (number(memory["memory_size"]) ?? 0) * 1024,
            memoryAvailableBytes: (number(memory["avail_real"]) ?? 0) * 1024,
            memoryCachedBytes: (number(memory["cached"]) ?? 0) * 1024,
            volumes: ((space["volume"] as? [[String: Any]]) ?? []).map { row in
                VolumeLoad(
                    id: (row["display_name"] as? String) ?? (row["device"] as? String) ?? "",
                    readBytesPerSec: number(row["read_byte"]) ?? 0,
                    writeBytesPerSec: number(row["write_byte"]) ?? 0,
                    utilization: Int(number(row["utilization"]) ?? 0)
                )
            },
            disks: diskRows.map { row in
                DiskLoad(
                    id: (row["device"] as? String) ?? "",
                    readBytesPerSec: number(row["read_byte"]) ?? 0,
                    writeBytesPerSec: number(row["write_byte"]) ?? 0,
                    utilization: Int(number(row["utilization"]) ?? 0)
                )
            }
        )
    }

    /// `Storage.CGI.Storage` v1 `load_info`。
    static func storage(_ manager: SessionManager) async throws -> SystemStorage {
        let raw = try await manager.call(
            kind: .file, api: "SYNO.Storage.CGI.Storage", version: 1, method: "load_info"
        )
        let data = (raw as? [String: Any]) ?? [:]
        let volumes = ((data["volumes"] as? [[String: Any]]) ?? []).map { row -> StorageVolume in
            let size = (row["size"] as? [String: Any]) ?? [:]
            return StorageVolume(
                id: (row["id"] as? String) ?? "",
                numID: Int(self.number(row["num_id"]) ?? 0),
                fsType: (row["fs_type"] as? String) ?? "",
                raidType: (row["raidType"] as? String) ?? "",
                status: (row["status"] as? String) ?? "",
                totalBytes: self.number(size["total"]) ?? 0,
                usedBytes: self.number(size["used"]) ?? 0,
                deviceBytes: self.number(size["total_device"]) ?? 0
            )
        }
        let disks = ((data["disks"] as? [[String: Any]]) ?? []).map { row -> StorageDisk in
            let life = (row["remain_life"] as? [String: Any]) ?? [:]
            // 型号里 WDC 的串是「WDC  WUH721818ALE6L4」—— 中间双空格是服务端原样，
            // 摆到界面前压成单空格（`vendor` 那种尾随空格顺路一起收掉）。
            // 参数收 `Any?`（字典取出来就是这型），别收 `String?` 逼着调用点硬转。
            func tidy(_ text: Any?) -> String {
                ((text as? String) ?? "").split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
            }
            return StorageDisk(
                id: (row["id"] as? String) ?? "",
                name: (row["name"] as? String) ?? "",
                model: tidy(row["model"]),
                vendor: tidy(row["vendor"]),
                sizeBytes: self.number(row["size_total"]) ?? 0,
                temperature: Int(self.number(row["temp"]) ?? 0),
                status: (row["status"] as? String) ?? "",
                smartStatus: (row["smart_status"] as? String) ?? "",
                remainLifeTrustable: self.bool(life["trustable"]),
                remainLifePercent: Int(self.number(life["value"]) ?? -1)
            )
        }
        return SystemStorage(volumes: volumes, disks: disks)
    }

    /// `Core.System.Status` v1 `get`。
    static func health(_ manager: SessionManager) async throws -> SystemHealth {
        let raw = try await manager.call(
            kind: .file, api: "SYNO.Core.System.Status", version: 1, method: "get"
        )
        let data = (raw as? [String: Any]) ?? [:]
        return SystemHealth(
            crashed: bool(data["is_system_crashed"]),
            nicIncompatible: bool(data["ext_nic_is_incompatible"])
        )
    }

    // MARK: - 解包与格式化

    /// 数字一律**收字符串**：这一组接口里 `size.total` / `size_total` / `model` 之外
    /// 的数值时而是数字、时而是字符串（`size` 整块都是字符串），`as? Int` 会全丢。
    private static func number(_ value: Any?) -> Int64? {
        if let text = value as? String {
            if let int = Int64(text) { return int }
            if let double = Double(text) { return Int64(double) }
            return nil
        }
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let double = value as? Double { return Int64(double) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text == "true" || text == "1" }
        return false
    }

    /// `up_time` 的 `"11:1:0"` → 秒。
    ///
    /// 🔴 **不补零**：`"11:1:0"` 是三段、每段任意位数，按定长切会切错。
    /// 协议是 `H:MM:SS`，小时这一段累计（DSM 的「信息中心」会显示「N 天」，
    /// 说明它不按 24 小时回绕）。
    static func seconds(_ text: String) -> Int {
        let parts = text.split(separator: ":").map { Int($0) ?? 0 }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// 吞吐：字节/秒 → `3.10 MB/s`。
    static func rateText(_ bytesPerSec: Int64) -> String {
        FileEntry.byteText(bytesPerSec) + "/s"
    }

    /// 开机时刻的显示：`10-14 11:27`。同一页里只出现一次，不带年份。
    static let bootStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    // MARK: - 四张状态卡

    /// 四张卡（温度 / CPU / 内存 / 运行时长）。
    ///
    /// 缺块时给 `—` + 「没读到」而不是把这张卡抽掉：四格的位置稳定，一眼能看出
    /// 是「这一项没读回来」而不是「这一项不存在」。
    static func stats(_ snapshot: SystemSnapshot?) -> [SystemStat] {
        let device = snapshot?.device
        let load = snapshot?.load
        return [temperatureStat(device), cpuStat(load, device: device),
                memoryStat(load), uptimeStat(device)]
    }

    private static func temperatureStat(_ device: SystemDevice?) -> SystemStat {
        guard let device else {
            return SystemStat(icon: "thermometer", label: "温度", value: "—", note: "没读到")
        }
        return SystemStat(
            icon: "thermometer", label: "温度",
            value: "\(device.temperature)", unit: "°C",
            note: device.temperatureWarn ? "偏高" : "正常",
            isWarning: device.temperatureWarn
        )
    }

    /// CPU：主值是**用户 + 系统**（DSM 自己的「利用率」口径，I/O 等待不算占用），
    /// 脚注给型号、核数与平均负载。
    private static func cpuStat(_ load: SystemLoad?, device: SystemDevice?) -> SystemStat {
        guard let load else {
            return SystemStat(icon: "cpu", label: "CPU", value: "—", note: "没读到")
        }
        var parts: [String] = []
        if let device {
            if !device.cpuSeries.isEmpty { parts.append(device.cpuSeries) }
            // 服务端只报物理核（R1600 是 2 核 4 线程，`cpu_cores` 给的是 2）。
            if device.cpuCores > 0 { parts.append("\(device.cpuCores) 核") }
        }
        parts.append(String(format: "负载 %.2f", load.load1))
        return SystemStat(
            icon: "cpu", label: "CPU",
            value: "\(load.cpuUsage)", unit: "%",
            note: parts.joined(separator: " · ")
        )
    }

    /// 内存：主值是 `real_usage`（DSM 的口径，不含缓存），脚注把缓存与可用摆出来
    /// —— 三个数是一套的（总 - 可用 - 缓存 ≈ 主值那份占用），不会互相打架。
    private static func memoryStat(_ load: SystemLoad?) -> SystemStat {
        guard let load else {
            return SystemStat(icon: "memory-stick", label: "内存", value: "—", note: "没读到")
        }
        let cached = FileEntry.byteText(load.memoryCachedBytes)
        let available = FileEntry.byteText(load.memoryAvailableBytes)
        return SystemStat(
            icon: "memory-stick", label: "内存",
            value: "\(load.memoryPercent)", unit: "%",
            note: "缓存 \(cached) · 可用 \(available)"
        )
    }

    private static func uptimeStat(_ device: SystemDevice?) -> SystemStat {
        guard let device else {
            return SystemStat(icon: "clock", label: "运行时长", value: "—", note: "没读到")
        }
        let hours = device.uptimeSeconds / 3600
        let value: String
        let unit: String
        if hours >= 24 {
            value = "\(hours / 24)"; unit = "天"
        } else if hours >= 1 {
            value = "\(hours)"; unit = "小时"
        } else {
            value = "\(max(1, device.uptimeSeconds / 60))"; unit = "分钟"
        }
        return SystemStat(
            icon: "clock", label: "运行时长", value: value, unit: unit,
            note: "开机于 " + bootStamp.string(from: device.bootedAt)
        )
    }
}
