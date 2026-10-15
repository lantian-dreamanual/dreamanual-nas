import Foundation

// ============ 标签编辑（Audio Station 网页端内部接口） ============
//
// 公开的 SYNO.AudioStation.Tag 只有读方法（38 个写方法名穷举全回 103），
// 写标签只能走网页端的私有 CGI `tagEditorUI/tag_editor.cgi`。
// 协议与判据都来自探针实测（experiments/shuffle-lab/NAS-接口结论.md 第三节，
// 2026-10-15 重探仍通）：
//   · `audioInfos` / `data` 是**字符串拼的 JSON 数组**，斜杠原样不转义；
//   · 读的回包在 `files`（不是 items），路径必须完整 `/music/…`；
//   · `success=true` 单独不可信（结构只到「不报错」时它也回 true）——
//     成败看 `files` 回显非空与 `write_fail_files`。

/// 一首歌的可编辑标签。`load` 回显什么就带什么字段，`apply` 原样写回 ——
/// 没给的字段服务端怎么处理没验证过，**全字段回传**是最稳的写法。
struct SongTagInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var genre: String
    var composer: String
    var comment: String
    var year: Int?
    var track: Int?
    var disc: Int?

    /// 编辑卡的草稿初值（NAS 现值到了再整体灌进去）。
    static let empty = SongTagInfo(title: "", artist: "", album: "", albumArtist: "",
                                   genre: "", composer: "", comment: "",
                                   year: nil, track: nil, disc: nil)
}

enum TagEditorError: LocalizedError {
    /// load 没回文件（路径不对 / 索引里没有这首）。
    case loadEmpty
    /// apply 没有回显成功（files 空或有 write_fail_files）。
    case notApplied

    var errorDescription: String? {
        switch self {
        case .loadEmpty: return "NAS 没有返回这首歌的标签信息"
        case .notApplied: return "写入没有生效（NAS 没有回显保存后的标签）"
        }
    }
}

enum TagEditor {
    /// 读一首歌的标签。`path` 用 `AudioSong.path`（完整 `/music/…`）。
    static func load(_ manager: SessionManager, path: String) async throws -> SongTagInfo {
        // 路径拼进 JSON 字符串；斜杠原样（JSONSerialization 默认转义 `/`，
        // 这条链路得靠 apply 那边的 .withoutEscapingSlashes，load 这边手工拼）。
        let infos = "[{\"path\":\"\(path)\"}]"
        let raw = try await manager.postTagEditor([
            "action": "load",
            "audioInfos": infos,
        ])
        guard let box = raw as? [String: Any],
              let files = box["files"] as? [[String: Any]],
              let first = files.first
        else { throw TagEditorError.loadEmpty }
        return SongTagInfo(
            title: jsonString(first["title"]),
            artist: jsonString(first["artist"]),
            album: jsonString(first["album"]),
            albumArtist: jsonString(first["album_artist"]),
            genre: jsonString(first["genre"]),
            composer: jsonString(first["composer"]),
            comment: jsonString(first["comment"]),
            year: jsonInt(first["year"]),
            track: jsonInt(first["track"]),
            disc: jsonInt(first["disc"])
        )
    }

    /// 把标签写回文件（真写 ID3，落盘即生效，索引 0 秒跟上）。
    /// 成败判据：`files` 回显非空，且 `write_fail_files` 为空。
    static func apply(_ manager: SessionManager, path: String, tags: SongTagInfo) async throws {
        var item: [String: Any] = [
            "audioInfos": [["path": path]],
            "title": tags.title,
            "artist": tags.artist,
            "album": tags.album,
            "album_artist": tags.albumArtist,
            "genre": tags.genre,
            "composer": tags.composer,
            "comment": tags.comment,
        ]
        if let year = tags.year { item["year"] = year }
        if let track = tags.track { item["track"] = track }
        if let disc = tags.disc { item["disc"] = disc }
        // data 必须是 JSON 数组；`.withoutEscapingSlashes` 保住路径里的 `/` 原样
        //（转义成 `\/` 服务端认不认没验过，探针当时就没转）。
        let data = try JSONSerialization.data(withJSONObject: [item],
                                              options: [.withoutEscapingSlashes])
        let raw = try await manager.postTagEditor([
            "action": "apply",
            "data": String(data: data, encoding: .utf8) ?? "",
        ])
        guard let box = raw as? [String: Any],
              let files = box["files"] as? [[String: Any]], !files.isEmpty
        else { throw TagEditorError.notApplied }
        if let fails = box["write_fail_files"] as? [[String: Any]], !fails.isEmpty {
            throw TagEditorError.notApplied
        }
    }
}
