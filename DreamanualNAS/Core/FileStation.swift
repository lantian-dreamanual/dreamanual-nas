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

    /// 字节数 → 人话（`3.88 MB` / `16.37 TB`），文件列表与系统状态页共用。
    ///
    /// TB 档是系统状态页那批补的：盘 16.37 TB、卷 15.71 TB，走 GB 档会显示成
    /// 「16764.00 GB」。文件列表那边不会有这么大的单件，档位加上对它没影响。
    static func byteText(_ bytes: Int64) -> String {
        dmByteText(bytes)
    }

    /// 列表里的时间戳：`2026-10-13 21:04`。列宽 150 正好放得下，不写秒。
    /// 列表与对照块共用这一套时间格式（`2026-10-08 21:33`）。
    static let stamp: DateFormatter = {
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

/// 一个目录的体积（`DirSize` 的 `status` 那一份）。
///
/// 字段就是服务端给的三件套：`total_size` / `num_dir` / `num_file`，**没有 `progress`**
/// —— 所以界面上「正在计算」只能是个转圈，画不出百分比。
struct DirectorySize: Equatable {
    let bytes: Int64
    let directories: Int
    let files: Int

    var text: String { FileEntry.byteText(bytes) }

    /// 悬停 / 副行里那句「12 个文件夹 · 340 个文件」。
    var detailText: String { "\(directories) 个文件夹 · \(files) 个文件" }
}

/// 搜索命中的一条。
///
/// 🔴 **只有三个字段**（`name` / `path` / `isdir`）—— `additional` 加上去也不认
/// （2026-10-14 实测：带了 `size,time,perm,type`，条目还是那三个键）。
/// 所以结果行**没有大小与时间**可以显示，只给名字、所在位置与「是不是目录」。
struct FileSearchHit: Identifiable, Equatable {
    let name: String
    let path: String
    let isDirectory: Bool

    var id: String { path }
    /// 所在目录（结果行右侧那条路径）。
    var parent: String { FileBrowser.parent(of: path) }
}

/// 搜索 `list` 的一次应答。三种状态分开（`接口结论.md` 第七节末）：
/// 还在跑（`total` 是过程值）/ 跑完（`total` 是终值）/ **假空**（连 `total` 键都没有）。
struct FileSearchPage {
    let hits: [FileSearchHit]
    /// **`nil` 就是假空** —— 应答里没有 `total` 键，服务端这次什么都没给。
    let total: Int?
    let finished: Bool

    var isFakeEmpty: Bool { finished && total == nil }
}

/// 一个文件任务的落地结果（`CopyMove` / `Delete` / `DirSize` 的 `status` 那一份）。
///
/// 🔴 `finished` 只说明任务停了，**不代表做成了** —— 判成败看 `errors`。
/// 实测：删非空目录且没给 `recursive` 时，任务报 `finished = true`、目录还在，
/// 错误藏在 `errors[{900, path}]` 里。
struct FileTask: Equatable {
    let finished: Bool
    /// 0–1。小文件太快时服务端给 1，而 `total` / `processed_size` 常是 0。
    let progress: Double
    let errors: [FileTaskError]
    /// `skipstatus.status`：**只说明这一批里有没有同名项**（`all` / `some`），
    /// 不是「跳过」的判据 —— 目录撞名时它照样报 `all`，而内容其实是合并了的
    /// （2026-10-14 实测）。要不要跳过由客户端先判，见 `FileTransfer`。
    let skipStatus: String?

    var failed: Bool { !errors.isEmpty }

    /// 给人话的失败说明（一条，多项时带个数）。
    var failureText: String {
        guard let first = errors.first else { return "" }
        guard errors.count > 1 else { return first.text }
        return "\(first.text)（另有 \(errors.count - 1) 项失败）"
    }
}

/// 任务 `errors[]` 里的一条。
struct FileTaskError: Equatable {
    let code: Int
    let path: String

    /// 码转人话。**只翻实测过的那两个**，其余把码原样带上 —— 码本身是查文档的钥匙，
    /// 认不出来的就别说成某个具体原因。
    var text: String {
        let name = path.isEmpty ? "" : "「\(path.split(separator: "/").last.map(String.init) ?? path)」"
        switch code {
        case 408: return "\(name)找不到了，可能已被移走。"
        case 414: return "\(name)名字重复了。"
        default: return "\(name)操作失败（code \(code)）。"
        }
    }
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

    // MARK: - 写操作

    /// 建文件夹（`CreateFolder` v2 `create`）。
    ///
    /// 🔴 **重名由调用方先查**（`exists(_:in:name:)`）：服务端对已存在的名字回
    /// `success` 并返回那个已存在目录的 path，实际什么也没做 —— 2026-10-14 复验过
    /// （目录里有文件、再建同名，内容与 `mtime` 都没变）。成功应答证明不了「新建了」。
    ///
    /// - Parameter forceParent: `true` 时父级不存在自动建；`false` 建多级回
    ///   `1100` + `errors[{408}]`。
    static func createFolder(
        _ manager: SessionManager,
        path: String,
        name: String,
        forceParent: Bool = false
    ) async throws {
        _ = try await manager.call(
            kind: .file,
            api: "SYNO.FileStation.CreateFolder",
            version: 2,
            method: "create",
            params: [
                "folder_path": path,
                "name": name,
                "force_parent": forceParent ? "true" : "false",
            ]
        )
    }

    /// 改名（`Rename` v2 `rename`）。`path` 与 `name` **两组一一对应** —— 长度不等
    /// 服务端直接回 HTTP 400（实测）。
    ///
    /// 🔴 撞名由**服务端拦**（`1200` + `errors[{414}]`），与建文件夹那条正好相反：
    /// 这里不必自己先查重名，把 `414` 翻成「该名称已存在」就行。
    static func rename(_ manager: SessionManager, path: String, to name: String) async throws {
        _ = try await manager.call(
            kind: .file,
            api: "SYNO.FileStation.Rename",
            version: 2,
            method: "rename",
            params: ["path": jsonArray([path]), "name": jsonArray([name])]
        )
    }

    /// 删除（`Delete` v2 `start` + `status` 轮询）。**异步任务**：`start` 只回 `taskid`，
    /// 结果要自己轮。
    ///
    /// 🔴 三条实测口径都写在这里，因为每一条都会让「看起来成功了」变成误删：
    ///   · `recursive` **不给就是递归删**，所以这里写死 `true` —— 删目录连内容一起，
    ///     这件事由确认弹窗对用户讲清楚；
    ///   · 任务报 `finished = true` **不等于成功**：没递归删非空目录时错误藏在
    ///     status 的 `errors[]` 里、目录还在 → 判成败只看 `errors`；
    ///   · 批量删里**不存在的条目被静默忽略**，不会出现在 `errors` 里。
    static func delete(_ manager: SessionManager, paths: [String]) async throws -> FileTask {
        guard !paths.isEmpty else { return FileTask(finished: true, progress: 1, errors: [], skipStatus: nil) }
        let raw = try await manager.call(
            kind: .file,
            api: "SYNO.FileStation.Delete",
            version: 2,
            method: "start",
            params: ["path": jsonArray(paths), "recursive": "true"]
        )
        let data = (raw as? [String: Any]) ?? [:]
        guard let taskid = data["taskid"] as? String else {
            throw QuickConnectError.badResponse("删除没有回任务号")
        }
        return try await awaitTask(
            manager, api: "SYNO.FileStation.Delete", version: 2,
            taskid: taskid, timeout: taskTimeout
        )
    }

    /// 复制 / 移动（`CopyMove` v3 `start` + `status` 轮询）。**异步任务**，与删除同形。
    ///
    /// 五条实测口径（2026-10-14 补测，`experiments/shuffle-lab/fswrite11.py`）：
    ///   · 目的目录的参数名是 **`dest_folder_path`**（`dest_folder` / `dst` 一律回 `400`）；
    ///   · `start` 对**不存在的源路径也回 `success` + `taskid`** —— 点对点应答只证明
    ///     「参数合法」，成败必须看任务；
    ///   · 撞名文件 + `overwrite=false` → **跳过**（目标内容不动）；撞名目录 → **合并**，
    ///     两个值都一样（`overwrite` 只管文件）；
    ///   · 🔴 **`name` / `new_name` / `rename_to` 三个键都被忽略**（三个都试过，复制过去
    ///     仍是原名）→ 接口**不能给新来的一份改名**，「保留两者」做不了，
    ///     所以复制 / 移动的撞名只有「替换 / 跳过」两选；
    ///   · 目标 = 源自己 / 源的子目录 → 任务层拦下（`errors[{1003, path}]`），不是静默。
    ///
    /// - Parameter move: `true` = 移动（`remove_src=true`）；`false` = 复制。
    static func copyMove(
        _ manager: SessionManager,
        paths: [String],
        to destination: String,
        move: Bool,
        overwrite: Bool
    ) async throws -> FileTask {
        guard !paths.isEmpty else { return FileTask(finished: true, progress: 1, errors: [], skipStatus: nil) }
        let raw = try await manager.call(
            kind: .file,
            api: "SYNO.FileStation.CopyMove",
            version: 3,
            method: "start",
            params: [
                "path": jsonArray(paths),
                "dest_folder_path": destination,
                "remove_src": move ? "true" : "false",
                "overwrite": overwrite ? "true" : "false",
            ]
        )
        let data = (raw as? [String: Any]) ?? [:]
        guard let taskid = data["taskid"] as? String else {
            throw QuickConnectError.badResponse("复制 / 移动没有回任务号")
        }
        return try await awaitTask(
            manager, api: "SYNO.FileStation.CopyMove", version: 3,
            taskid: taskid, timeout: taskTimeout
        )
    }

    /// 停掉一个复制 / 移动任务。实测 `CopyMove` **有** `stop` 方法（回 `success`），
    /// 是给「大目录传到一半想反悔」留的；本批界面没挂取消（复制走的是 NAS 本地磁盘，
    /// 不占中继带宽，弹窗一关就等结果）。
    static func stopCopyMove(_ manager: SessionManager, taskid: String) async throws {
        _ = try await manager.call(
            kind: .file,
            api: "SYNO.FileStation.CopyMove",
            version: 3,
            method: "stop",
            params: ["taskid": taskid]
        )
    }

    /// 上传一个文件到 `directory`（`Upload` v2 `upload`，multipart）。
    ///
    /// 两个字段的档位由这里定死，原因都在实测里：
    ///   · `create_parents=true` —— 传「文件夹里的文件」时目的目录可能还不存在，
    ///     `false` 会回 `408`；真建目录由服务端顺手做掉，省一次 `CreateFolder`；
    ///   · `overwrite=true` —— `false` 撞名回「成功」但内容不变（静默跳过），
    ///     要不要覆盖是**界面先问过用户**的决定，到这里就是照办。
    ///
    /// 🔴 **上传的撞名必须调用方先查**（与建文件夹同理、与改名相反）：`overwrite=false`
    /// 那条路服务端连冲突都不报。`UploadQueue` 就是因为这条才在做客户端重名比对。
    ///
    /// - Parameter name: 落地的文件名。**不能带斜杠**（`sub/a.txt` → `418`）——
    ///   文件夹上传靠目的目录带层级，不靠文件名带。
    static func upload(
        _ manager: SessionManager,
        fileURL: URL,
        name: String,
        to directory: String,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        _ = try await manager.upload(
            kind: .file,
            api: "SYNO.FileStation.Upload",
            version: 2,
            method: "upload",
            fields: ["path": directory, "create_parents": "true", "overwrite": "true"],
            fileName: name,
            fileURL: fileURL,
            progress: progress
        )
    }

    /// 目录里有没有叫这个名字的项 —— 建文件夹前的重名探测。
    ///
    /// 建文件夹那条接口**重名回成功**，所以这一步不能省；一次拉满（5000）而不是
    /// 只看当前这一页：`/music` 顶层 3613 个目录，只看第一页会漏掉大部分重名。
    static func exists(_ manager: SessionManager, in directory: String, name: String) async throws -> Bool {
        let page = try await list(
            manager, path: directory, sort: FileStation.defaultSort, limit: treeFetchLimit
        )
        return page.entries.contains { $0.name == name }
    }

    // MARK: - 搜索（Search v2）

    /// 起一次搜索（`Search` v2 `start`）。`pattern` 是**名字子串**：不吃通配符
    /// （`*.mp3` 回 0），大小写不敏感，中文照搜（实测 `饼羊` 命中 7 条）。
    ///
    /// 🔴 `start` 回 `success` + `taskid` **不证明这个任务真的建起来了**（与
    /// `CopyMove` 同族），而且搜索的坑在 `list` 那一侧（假空），所以这里只负责拿任务号。
    static func searchStart(
        _ manager: SessionManager,
        folder: String,
        pattern: String
    ) async throws -> String {
        let raw = try await manager.call(
            kind: .file,
            api: "SYNO.FileStation.Search",
            version: 2,
            method: "start",
            params: ["folder_path": folder, "pattern": pattern, "recursive": "true"]
        )
        let data = (raw as? [String: Any]) ?? [:]
        guard let taskid = data["taskid"] as? String, !taskid.isEmpty else {
            throw QuickConnectError.badResponse("搜索没有回任务号")
        }
        return taskid
    }

    /// 取一页结果（`Search` v2 `list`）。
    ///
    /// 三种应答必须分清（`接口结论.md` 第七节末）：还在跑 → `finished = false`、`total` 是
    /// **已索引条数的过程值**（只会涨，不能当结果数）；跑完 → `finished = true` + `total`
    /// 是终值；🔴 **假空** → `finished = true` 而**连 `total` 键都没有** —— 服务端这次什么
    /// 都没给，不是「0 条」。真零长这样：`{"files": [], "finished": true, "total": 0}`。
    ///
    /// ⚠️ 条目只有 `name` / `path` / `isdir` 三个键（`additional` 不认）。
    static func searchPage(
        _ manager: SessionManager,
        taskid: String,
        offset: Int,
        limit: Int
    ) async throws -> FileSearchPage {
        let raw = try await manager.call(
            kind: .file,
            api: "SYNO.FileStation.Search",
            version: 2,
            method: "list",
            params: ["taskid": taskid, "offset": String(offset), "limit": String(limit)]
        )
        let data = (raw as? [String: Any]) ?? [:]
        let files = (data["files"] as? [[String: Any]]) ?? []
        return FileSearchPage(
            hits: files.map { dict in
                FileSearchHit(
                    name: (dict["name"] as? String) ?? "",
                    path: (dict["path"] as? String) ?? "",
                    isDirectory: (dict["isdir"] as? Bool) ?? false
                )
            },
            // 🔴 没有 `total` 键就是假空 —— 不能用 `?? 0` 吞掉这个区别。
            total: integer(data["total"]).map(Int.init),
            finished: (data["finished"] as? Bool) ?? false
        )
    }

    /// 停掉一次搜索。假空之后要 stop 再重来（实测这么写才出得来结果）。
    static func searchStop(_ manager: SessionManager, taskid: String) async {
        _ = try? await manager.call(
            kind: .file, api: "SYNO.FileStation.Search", version: 2,
            method: "stop", params: ["taskid": taskid]
        )
    }

    /// 把任务连同结果一起清掉（`clean` 实测存在，回 `{}`；`delete` / `clear` 回 `103`）。
    /// **界面搜完要 clean** —— 不清就在服务端攒任务。
    static func searchClean(_ manager: SessionManager, taskid: String) async {
        _ = try? await manager.call(
            kind: .file, api: "SYNO.FileStation.Search", version: 2,
            method: "clean", params: ["taskid": taskid]
        )
    }

    // MARK: - 目录大小（DirSize v2）

    /// 算一个或多个目录的体积（`DirSize` v2 `start` + `status` 轮询）。
    ///
    /// 四条实测口径（2026-10-14，`experiments/shuffle-lab/dirsearch1–6.py`）：
    ///   · `path` 给 **JSON 数组串**，多个目录会**求和**（实测两条路径的值精确等于各自之和）；
    ///     给表单重复参数（`path=a&path=b`）只算**最后一条** —— 别用那个写法；
    ///   · 🔴 `status` 会**随机回 `599`**，而且那是**这个任务号坏了**，不是读一次抖一下
    ///     （实测一个坏号连读 12 次全是 599）。`start` 回 `success` + `taskid` 同样不证明
    ///     任务建起来了 → 判据是「**首次 `status` 不成功就丢掉任务号、换一次 `start`**」。
    ///     坏号在第一次轮询就看得出来（约 0.2 秒），所以重试很便宜；实测小目录平均要 3~5 次；
    ///   · **没有 `progress`**，只有 `total_size` / `num_dir` / `num_file` → 界面只能显示「正在计算」；
    ///   · 慢：`/music`（9368 目录 / 18080 文件）实测 **29 秒** → 界面必须按需触发、不能进目录就算。
    ///
    /// - Parameter attempts: `start` 重试上限。实测成功率低：同一个目录打 10 次，**局域网直连**
    ///   认 4 次、**QuickConnect 中继**认 2 次（2026-10-14 对照，链路差异不在接口）；
    ///   一个坏号在第一次轮询就看得出来，所以重试很便宜。给 10 次约九成能成。
    static func directorySize(
        _ manager: SessionManager,
        paths: [String],
        attempts: Int = 10
    ) async throws -> DirectorySize {
        guard !paths.isEmpty else { return DirectorySize(bytes: 0, directories: 0, files: 0) }
        var lastError: Error?
        for _ in 0..<max(1, attempts) {
            var taskid = ""
            do {
                let raw = try await manager.call(
                    kind: .file, api: "SYNO.FileStation.DirSize", version: 2, method: "start",
                    params: ["path": jsonArray(paths)]
                )
                let data = (raw as? [String: Any]) ?? [:]
                taskid = (data["taskid"] as? String) ?? ""
                guard !taskid.isEmpty else {
                    lastError = QuickConnectError.badResponse("算目录大小没有回任务号")
                    continue
                }
                return try await awaitDirectorySize(manager, taskid: taskid)
            } catch let error as SynologyError where error.code == Self.badTaskCode {
                // 这个任务号是坏的 —— 收掉它，换一次 start 重来。
                lastError = error
                if !taskid.isEmpty { await stopDirectorySize(manager, taskid: taskid) }
            }
        }
        throw lastError ?? QuickConnectError.badResponse("算不出这个文件夹的大小")
    }

    /// 算完了但用户不等了（`DirSize` **有** `stop`，实测回 `success`）。
    static func stopDirectorySize(_ manager: SessionManager, taskid: String) async {
        _ = try? await manager.call(
            kind: .file, api: "SYNO.FileStation.DirSize", version: 2,
            method: "stop", params: ["taskid": taskid]
        )
    }

    /// 🔴 `599` = 「这个任务号查不到」。实测里 `DirSize` 的任务号有一半左右是坏的，
    /// 而且坏号**一直坏**（连读 12 次全是 599），所以它是重试的判据。
    static let badTaskCode = 599

    /// 大目录也算得完：`/music` 实测 29 秒，给足一倍余量。
    static let dirSizeTimeout: TimeInterval = 90

    private static func awaitDirectorySize(
        _ manager: SessionManager,
        taskid: String
    ) async throws -> DirectorySize {
        let deadline = Date().addingTimeInterval(dirSizeTimeout)
        while Date() < deadline {
            let raw = try await manager.call(
                kind: .file, api: "SYNO.FileStation.DirSize", version: 2,
                method: "status", params: ["taskid": taskid]
            )
            let data = (raw as? [String: Any]) ?? [:]
            if (data["finished"] as? Bool) == true {
                return DirectorySize(
                    bytes: integer(data["total_size"]) ?? 0,
                    directories: integer(data["num_dir"]).map(Int.init) ?? 0,
                    files: integer(data["num_file"]).map(Int.init) ?? 0
                )
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        throw QuickConnectError.badResponse("算目录大小超时（\(Int(dirSizeTimeout)) 秒）")
    }

    /// 等一个文件任务落地（`status` 轮询）。`CopyMove` / `Delete` / `DirSize` 都是这个形状。
    ///
    /// 超时按失败抛 —— 任务号还在但总不 finished 的场合（网络断了、NAS 忙），
    /// 让界面知道「没等到结果」，别默认成功。
    static func awaitTask(
        _ manager: SessionManager,
        api: String,
        version: Int,
        taskid: String,
        timeout: TimeInterval
    ) async throws -> FileTask {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let raw = try await manager.call(
                kind: .file, api: api, version: version, method: "status", params: ["taskid": taskid]
            )
            let task = decodeTask((raw as? [String: Any]) ?? [:])
            if task.finished { return task }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        throw QuickConnectError.badResponse("操作超时（\(Int(timeout)) 秒没等到结果）")
    }

    /// 文件任务等多久。删除一棵大目录会慢，给足；轮询间隔 0.4 秒。
    static let taskTimeout: TimeInterval = 60

    static func decodeTask(_ dict: [String: Any]) -> FileTask {
        let errors = ((dict["errors"] as? [[String: Any]]) ?? []).map { err in
            FileTaskError(
                code: (err["code"] as? NSNumber)?.intValue ?? -1,
                path: (err["path"] as? String) ?? ""
            )
        }
        return FileTask(
            finished: (dict["finished"] as? Bool) ?? false,
            progress: (dict["progress"] as? NSNumber)?.doubleValue ?? 0,
            errors: errors,
            skipStatus: (dict["skipstatus"] as? [String: Any])?["status"] as? String
        )
    }

    /// 写接口的数组参数形态：**JSON 数组串**（`["a","b"]`）。实测 `path` / `name`
    /// 都认这个；给纯字符串只当单项。
    ///
    /// 用 `JSONSerialization` 生成而不是手拼：名称里可能带引号、反斜杠、换行。
    static func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
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
