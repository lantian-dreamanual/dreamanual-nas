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
/// 链路（2026-10-15 第二版，当天踩坑改的）：小组件 extension **必须沙箱**
/// —— macOS 不注册非沙箱的 app extension，图库静默不出现；而 App Group
/// 容器在 ad-hoc 签名下拿不到（containerURL 回 nil）。落点走业界已验证的
/// 通路：主 app（非沙箱）直接写 widget 的沙箱容器
/// `~/Library/Containers/com.dreamanual.nas.widget/Data/Library/Application
/// Support/DreamanualNAS/widget-state.json`，沙箱内的 widget 用自己的
/// Application Support 读（`NSHomeDirectory` 在沙箱里映射到容器 Data）。
/// 两个约束：容器目录必须由 macOS 在 extension 首次启动时创建，主 app
/// **只在容器已存在时才写**（手工 mkdir 缺 container metadata 会挡住
/// extension 启动）；extension 没启动过之前没有快照，小组件首加显示
/// 离线态，等主 app 下一次推送（页面刷新 / 15 分钟一拍）就有了。
///
/// 口令随快照带（`password` 字段）：沙箱里读不了主 app 的 credential.json，
/// 自拉链路的口令只能走这份快照。敏感级别说明照旧 —— 明文文件 0600 +
/// FileVault 兜底，与 credential.json 同档。
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

    // 连接三件套 + 端点身份 + 口令：小组件自拉时按这套直接连。
    // 三件套在主 app 的 UserDefaults.standard 里，widget 进程读不到，
    // 只能随快照带；口令同理（credential.json 在沙箱外）。
    var endpointKey: String
    var qcID: String
    var directAddress: String
    var username: String
    /// 自拉用的口令。可选是为了旧快照（没这字段）也能解出来。
    var password: String?

    /// 快照还算不算新鲜。30 分钟内的数据小组件直接用，过了就得自己拉。
    func isFresh(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(takenAt) < 30 * 60
    }
}

enum WidgetBridge {
    /// widget extension 的 bundle id：主 app 侧靠它拼沙箱容器路径。
    static let widgetBundleID = "com.dreamanual.nas.widget"

    /// 当前进程是不是 widget extension 自己。
    static var isWidgetProcess: Bool {
        Bundle.main.bundleIdentifier == widgetBundleID
    }

    /// widget 进程（沙箱内）：自己的 Application Support，`NSHomeDirectory`
    /// 被沙箱映射到容器 `Data/`；主 app 进程（非沙箱）：直写 widget 的
    /// 沙箱容器。两个分支都以 `DreamanualNAS/widget-state.json` 收尾，
    /// 同一份源码两端编译，落点天然对齐。
    static var fileURL: URL {
        if isWidgetProcess {
            return FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DreamanualNAS/widget-state.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(widgetBundleID)/Data/Library/Application Support/DreamanualNAS/widget-state.json"
            )
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
    /// 口令从 credential.json 取来随快照带（沙箱里的 widget 读不了那盘文件）。
    static func publish(_ snapshot: SystemSnapshot,
                        endpointKey: String, qcID: String,
                        directAddress: String, username: String,
                        password: String) async {
        guard var data = make(from: snapshot, endpointKey: endpointKey, qcID: qcID,
                              directAddress: directAddress, username: username)
        else { return }
        data.password = password.isEmpty ? nil : password
        save(data)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func save(_ data: WidgetSnapshotData) {
        let dir = fileURL.deletingLastPathComponent()
        // 主 app 侧：容器还没建起来（widget 没被系统启动过）就先不写 ——
        // 手工 mkdir 的容器缺 container metadata，反而会挡住 extension 启动。
        // widget 进程自己的 Application Support 目录由沙箱兜底，无此顾虑。
        if !isWidgetProcess, !FileManager.default.fileExists(atPath: dir.path) { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let json = try? encoder.encode(data) else { return }
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
