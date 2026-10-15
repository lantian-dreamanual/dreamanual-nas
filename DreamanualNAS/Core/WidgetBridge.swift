import Foundation
import WidgetKit

// ============ 桌面小组件的共享快照 ============

/// 字节数 → 人话（`B / KB / MB / GB / TB`，TB 2026-10-14 补）。
/// 原本只在 `FileEntry` 上；小组件的状态卡也用它，提为顶层函数 ——
/// `FileEntry.byteText` 现在只是转发，旧调用点不用动。
func dmByteText(_ bytes: Int64) -> String {
    let unit: Double = 1024
    let value = Double(bytes)
    if bytes < 1024 { return "\(bytes) B" }
    if value < unit * unit { return String(format: "%.1f KB", value / unit) }
    if value < unit * unit * unit { return String(format: "%.1f MB", value / unit / unit) }
    if value < unit * unit * unit * unit {
        return String(format: "%.2f GB", value / unit / unit / unit)
    }
    return String(format: "%.2f TB", value / unit / unit / unit / unit)
}


/// 主 app 与小组件之间递数据的那张纸。
///
/// 链路（2026-10-15 定）：主 app 活着 → 每次拉到状态就写进
/// `~/Library/Application Support/DreamanualNAS/widget-state.json` 并捅一次
/// 时间线；小组件刷新时**优先读这份**（新鲜、不用登录），超过 30 分钟才
/// 自己连一次 NAS（凭据在旁边的 `credential.json`，连接信息随快照带过来）。
///
/// 为什么不上 App Group：主 app 与 extension 都是**非沙箱**（自分发、ad-hoc
/// 签名），同用户直接读写 Application Support 就通，App Group 的 entitlement
/// 在 ad-hoc 签名下能不能用还没验过 —— 能少一个变量就少一个变量。
struct WidgetSnapshotData: Codable {
    struct Disk: Codable, Equatable {
        var name: String
        var temperature: Int
        var healthy: Bool
    }

    var takenAt: Date
    var temperature: Int
    var temperatureWarn: Bool
    var cpuUsage: Int
    var volumeUsed: Int64
    var volumeTotal: Int64
    var disks: [Disk]
    /// 上次关机不正常（`is_system_crashed`）—— 小组件顶行转红。
    var crashed: Bool

    // 连接三件套 + 端点身份：小组件自拉时按它拼 `endpointKey` 去取口令。
    // 这里只有「去哪连、用哪个账号」，口令本体在 credential.json（0600），
    // 这份快照不比它更敏感，权限照抄同一档。
    var endpointKey: String
    var qcID: String
    var directAddress: String
    var username: String

    /// 快照还算不算新鲜。30 分钟内的数据小组件直接用，过了就得自己拉。
    func isFresh(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(takenAt) < 30 * 60
    }
}

enum WidgetBridge {
    /// 与 `credential.json` 同目录、同权限档。
    static var fileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DreamanualNAS/widget-state.json")
    }

    /// 从一份系统快照拼小组件数据。四块里缺了**任何一块**就回 nil ——
    /// 宁可保留旧快照，也别拿半截数据把小组件刷成错的。
    static func make(from snapshot: SystemSnapshot,
                     endpointKey: String, qcID: String,
                     directAddress: String, username: String) -> WidgetSnapshotData? {
        guard let device = snapshot.device,
              let load = snapshot.load,
              let volume = snapshot.storage?.volumes.first
        else { return nil }
        return WidgetSnapshotData(
            takenAt: snapshot.takenAt,
            temperature: device.temperature,
            temperatureWarn: device.temperatureWarn,
            cpuUsage: load.cpuUsage,
            volumeUsed: volume.usedBytes,
            volumeTotal: volume.totalBytes,
            disks: (snapshot.storage?.disks ?? []).map {
                .init(name: $0.name, temperature: $0.temperature, healthy: $0.isHealthy)
            },
            crashed: snapshot.health?.crashed ?? false,
            endpointKey: endpointKey, qcID: qcID,
            directAddress: directAddress, username: username
        )
    }

    /// 主 app 侧：状态拉成功（页面刷新 / 周期推送）就落盘 + 捅一次时间线。
    static func publish(_ snapshot: SystemSnapshot,
                        endpointKey: String, qcID: String,
                        directAddress: String, username: String) async {
        guard let data = make(from: snapshot, endpointKey: endpointKey, qcID: qcID,
                              directAddress: directAddress, username: username)
        else { return }
        save(data)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func save(_ data: WidgetSnapshotData) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let json = try? encoder.encode(data) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? json.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    static func read() -> WidgetSnapshotData? {
        guard let json = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshotData.self, from: json)
    }
}

/// 直连地址解析：接受 `主机`、`主机:端口`、`https://主机:端口`。
/// （从 AppState.swift 挪过来 —— 小组件自拉也要拆这行地址，两边共用一份。）
struct DirectAddress {
    let host: String
    let port: Int

    static func parse(_ text: String) -> DirectAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var rest = trimmed
        for scheme in ["https://", "http://"] where rest.hasPrefix(scheme) {
            rest = String(rest.dropFirst(scheme.count))
        }
        rest = rest.split(separator: "/").first.map(String.init) ?? rest

        let parts = rest.split(separator: ":")
        switch parts.count {
        case 1:
            return DirectAddress(host: String(parts[0]), port: 5001)
        case 2:
            guard let port = Int(parts[1]) else { return nil }
            return DirectAddress(host: String(parts[0]), port: port)
        default:
            return nil
        }
    }
}
