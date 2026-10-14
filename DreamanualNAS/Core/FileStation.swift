import Foundation

/// 文件管理里的一条条目（文件或目录）。
struct FileEntry: Identifiable, Equatable {
    /// 分类型选图标与缩略图用。**只看 `additional.type`**，不从文件名切扩展名
    /// （`接口结论.md` 第七节第 1 条：扩展名大小写与多后缀都会让自切判错）。
    enum Kind {
        case folder, image, video, audio, archive, text, other
    }

    let name: String
    let path: String
    let isDirectory: Bool
    /// 字节数。🔴 **目录也有数**（DSM 回的是目录自身的大小，实测 176 这种），
    /// 不是内容合计 —— 界面给目录留空，别把 176 当成这个目录的体积。
    let size: Int64?
    /// 修改时间（`additional.time.mtime`，Unix 秒）。
    let modified: Date?
    /// 扩展名，**大写**（`MP3` / `MP4`）；目录为空串。
    let type: String
    let owner: String
    /// 可写性判据：`additional.perm.acl.write`。实测在 `perm.acl` 下（Bool）。
    /// 本批只读，先存着 —— 写操作批次要拿它把不可写目录的操作灰掉。
    let canWrite: Bool

    var id: String { path }

    var kind: Kind {
        if isDirectory { return .folder }
        switch type.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "avif":
            return .image
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp", "ts", "flv", "wmv":
            return .video
        case "mp3", "flac", "m4a", "aac", "wav", "ogg", "oga", "opus", "ape", "wma", "aiff", "alac":
            return .audio
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return .archive
        case "txt", "md", "ini", "conf", "cfg", "log", "json", "xml", "yaml", "yml",
             "srt", "ass", "lrc", "csv", "tsv", "html", "css", "js", "sh", "py":
            return .text
        default:
            return .other
        }
    }

    /// 28 的缩略图格能出图的类型 —— 与 `FileStation.Thumb` 的实测一致：
    /// 图片与视频出图，音频与非媒体一律 404。
    var hasThumbnail: Bool { kind == .image || kind == .video }

    var sizeText: String {
        guard !isDirectory, let size else { return "" }
        return FileEntry.byteText(size)
    }

    var modifiedText: String {
        guard let modified else { return "" }
        return FileEntry.stamp.string(from: modified)
    }

    /// 一行里给「大小」列用的原始字节数（排序、合计都读它；目录记 0）。
    var byteCount: Int64 { isDirectory ? 0 : (size ?? 0) }

    static func byteText(_ bytes: Int64) -> String {
        let unit: Double = 1024
        let value = Double(bytes)
        if bytes < 1024 { return "\(bytes) B" }
        if value < unit * unit { return String(format: "%.1f KB", value / unit) }
        if value < unit * unit * unit { return String(format: "%.1f MB", value / unit / unit) }
        return String(format: "%.2f GB", value / unit / unit / unit)
    }

    /// 列表里的时间戳：`2026-10-13 21:04`。列宽 150 正好放得下，不写秒。
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// 一个共享文件夹（`list_share` 的应答条目）。
struct FileShare: Identifiable, Equatable {
    let name: String
    let path: String
    let canWrite: Bool

    var id: String { path }
}

/// 文件表可排的三列。**这三列是实测被服务端认下的**（2026-10-14）：
/// `name` / `size` / `mtime` 都能排；`time` / `type` / `owner` / `posix` 不认
/// （静默退回按名字排，不报错），所以界面只暴露这三列。
enum FileSortField: String, CaseIterable, Identifiable {
    case name, size, mtime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .mtime: return "修改时间"
        }
    }

    /// 列宽。名称列自适应（保底 `FilesMetrics.nameMinWidth`），末位由表头补一格。
    var width: CGFloat? {
        switch self {
        case .name: return nil
        case .size: return 110
        case .mtime: return 150
        }
    }

    var isNumeric: Bool { self == .size }
}

struct FileSort: Equatable {
    let field: FileSortField
    let ascending: Bool

    var direction: String { ascending ? "asc" : "desc" }

    /// 进 URL 的字段名。**列名与接口字段名同一套**（`name` / `size` / `mtime`）——
    /// 中间再起一套别名，改一处忘一处就静默退回默认顺序。
    var apiField: String { field.rawValue }
}

struct FilePage {
    let entries: [FileEntry]
    let total: Int
}

/// 文件管理只读那一路的接口。
///
/// 三条实测硬约束（`docs/接口结论.md` 第七节，2026-10-14 复验）：
///   · `folder_path` 给**纯字符串**，给 JSON 数组回 HTTP 502；
///   · `additional` 反过来**只认 JSON 数组**，逗号串被静默忽略（条目只剩三个字段）；
///   · 取流 / 取图 / 取缩略图必须带 `X-SYNO-TOKEN`，只带 `_sid` 会回 200 + JSON 错误。
enum FileStation {
    /// 树与列表默认的排序：**名称正序**。原型里「逐级懒加载」那一条也写明按名称正序拉。
    static let defaultSort = FileSort(field: .name, ascending: true)

    /// 目录树一层最多拉这么多 —— 实测 `limit=5000` 服务端照收（`/music` 顶层 3621 项
    /// 一次拿全），树只需要目录、不翻页。
    static let treeFetchLimit = 5000

    private static let additional = #"["size","time","type","perm","owner"]"#

    static func shares(_ manager: SessionManager) async throws -> [FileShare] {
        let raw = try await manager.call(
            kind: .file,
            api: "SYNO.FileStation.List",
            version: 2,
            method: "list_share",
            params: ["additional": additional]
        )
        let data = (raw as? [String: Any]) ?? [:]
        return (data["shares"] as? [[String: Any]] ?? []).map(decodeShare)
    }

    /// 列一层目录。
    ///
    /// - Parameters:
    ///   - sort: `nil` 走服务端默认顺序（名称正序）。**排序交给服务端**：
    ///     与曲库快照同理，翻页时只排当前这一页的话，第二页会又按默认顺序接在后面。
    static func list(
        _ manager: SessionManager,
        path: String,
        sort: FileSort?,
        offset: Int = 0,
        limit: Int = 1000
    ) async throws -> FilePage {
        var params: [String: String] = [
            "folder_path": path,
            "additional": additional,
            "offset": String(offset),
            "limit": String(limit),
        ]
        if let sort {
            params["sort_by"] = sort.apiField
            params["sort_direction"] = sort.direction
        }
        let raw = try await manager.call(
            kind: .file,
            api: "SYNO.FileStation.List",
            version: 2,
            method: "list",
            params: params
        )
        let data = (raw as? [String: Any]) ?? [:]
        let files = (data["files"] as? [[String: Any]]) ?? []
        return FilePage(
            entries: files.map(decodeEntry),
            total: integer(data["total"]).map(Int.init) ?? files.count
        )
    }

    /// 缩略图（`FileStation.Thumb` v3 `get`）。图片与视频出图，音频与非媒体回 404
    /// —— 取不到不是异常，界面退回图标。
    static func thumbnail(_ manager: SessionManager, path: String) async throws -> Data {
        try await manager.data(
            kind: .file,
            api: "SYNO.FileStation.Thumb",
            version: 3,
            method: "get",
            params: ["path": path, "size": "small", "rotate": "0"]
        )
    }

    // MARK: - 解包

    /// `additional` 里全在，顶层只有 `name` / `isdir` / `path` 三个。
    static func decodeEntry(_ dict: [String: Any]) -> FileEntry {
        let extra = (dict["additional"] as? [String: Any]) ?? [:]
        let time = (extra["time"] as? [String: Any]) ?? [:]
        let perm = (extra["perm"] as? [String: Any]) ?? [:]
        let acl = (perm["acl"] as? [String: Any]) ?? [:]
        return FileEntry(
            name: (dict["name"] as? String) ?? "",
            path: (dict["path"] as? String) ?? "",
            isDirectory: (dict["isdir"] as? Bool) ?? false,
            size: integer(extra["size"]),
            modified: integer(time["mtime"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            type: (extra["type"] as? String) ?? "",
            owner: ((extra["owner"] as? [String: Any])?["user"] as? String) ?? "",
            canWrite: (acl["write"] as? Bool) ?? false
        )
    }

    static func decodeShare(_ dict: [String: Any]) -> FileShare {
        let extra = (dict["additional"] as? [String: Any]) ?? [:]
        let perm = (extra["perm"] as? [String: Any]) ?? [:]
        let acl = (perm["acl"] as? [String: Any]) ?? [:]
        return FileShare(
            name: (dict["name"] as? String) ?? "",
            path: (dict["path"] as? String) ?? "",
            canWrite: (acl["write"] as? Bool) ?? false
        )
    }

    /// JSONSerialization 给的是 `NSNumber`（桥到 `Int`），直接 `as? Int64` 不一定成立。
    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let double = value as? Double { return Int64(double) }
        return nil
    }
}
