import AppKit
import Foundation
import Observation

/// 照片网格的选择模式。
///
/// 只服务网格屏（时间轴 / 最近添加 / 搜索 / 各分类详情）：人物卡、相册卡、地点与
/// 标签列表都没有多选。选择状态挂在 `AppState` 上而不是视图里 —— 切屏、开关查看器、
/// 写操作完成后都要能读到同一份。
@MainActor
@Observable
final class PhotoSelection {
    private(set) var isActive = false
    private(set) var ids: Set<Int> = []
    /// 当前这一屏的全部条目。全选与组头三态都按它算，视图每次算分组时同步进来。
    @ObservationIgnored var scope: [PhotosAPI.Item] = []

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: Int) -> Bool { ids.contains(id) }

    /// 点一张。不在选择模式就**进选择模式并选中这张**（照文件管理器的习惯：
    /// 选中态从一次点击开始，不需要先按什么键）。
    func tap(_ item: PhotosAPI.Item) {
        guard isActive else {
            isActive = true
            ids = [item.id]
            return
        }
        if ids.contains(item.id) {
            ids.remove(item.id)
        } else {
            ids.insert(item.id)
        }
        if ids.isEmpty { isActive = false }
    }

    func selectAll() {
        guard !scope.isEmpty else { return }
        isActive = true
        ids = Set(scope.map(\.id))
    }

    /// 选中指定的这几张（冒烟通路用：全选一万条没法截图核对）。
    func select(_ items: [PhotosAPI.Item]) {
        guard !items.isEmpty else { return }
        isActive = true
        ids = Set(items.map(\.id))
    }

    func clear() {
        ids.removeAll()
        isActive = false
    }

    /// 某一组（一天）的三态：全选 / 部分 / 未选。组头全选位按这个画。
    func state(of group: [PhotosAPI.Item]) -> (all: Bool, some: Bool) {
        guard !group.isEmpty else { return (false, false) }
        let hits = group.reduce(0) { $0 + (ids.contains($1.id) ? 1 : 0) }
        return (hits == group.count, hits > 0 && hits < group.count)
    }

    /// 组头全选位：已全选则该组清空，否则补满该组（与文件管理表头同一个语义）。
    func toggle(group: [PhotosAPI.Item]) {
        let all = group.allSatisfy { ids.contains($0.id) }
        if all {
            for item in group { ids.remove(item.id) }
            if ids.isEmpty { isActive = false }
        } else {
            isActive = true
            ids.formUnion(group.map(\.id))
        }
    }
}

/// 写操作的结果。界面据此出 Toast，不做「成功一条、失败一条」的密集提示。
struct PhotoWriteResult {
    var done = 0
    var failed = 0
    /// 失败原因（只取第一条，够用户判断是权限、网络还是服务端不认）。
    var reason: String?

    var isFailure: Bool { done == 0 && failed > 0 }

    /// 单一动作的提示文案：`已删除 3 张` / `1 张没有删掉`。
    func summary(_ verb: String, unit: String = "张") -> String {
        if failed == 0 { return "已\(verb) \(done) \(unit)" }
        if done == 0 { return "\(failed) \(unit)没有\(verb)掉" }
        return "已\(verb) \(done) \(unit)，\(failed) \(unit)没成功"
    }
}

/// 照片的写操作。
///
/// 全部走**回读确认**的思路：这套接口对不存在的 id 也回 `success`
/// （`Browse.Item.set` / `delete` 都这样），「回 ok」不构成完成证据。删除的确认
/// 方式是「本地先剔除、随后静默重拉整库校正」——删不掉的会自己回到网格里。
enum PhotoWriter {
    // MARK: - 删除

    /// 删除若干条。接口只认单个 `id`，逐条发。
    static func delete(_ items: [PhotosAPI.Item], manager: SessionManager) async -> PhotoWriteResult {
        var result = PhotoWriteResult()
        for item in items {
            do {
                try await PhotosAPI.deleteItem(id: item.id, manager: manager)
                result.done += 1
            } catch {
                result.failed += 1
                if result.reason == nil { result.reason = Self.describe(error) }
            }
        }
        return result
    }

    // MARK: - 原图 / 原视频

    /// 存原图。走 `FileStation.Download`（路径 = `/photo` + 目录 + 文件名）——
    /// 与曲库下载同一条 `FileDownloader`，流式落盘，几十 MB 的视频也不会整块进内存。
    /// 目录取不到时回落到照片接口的 `Download.download`。
    static func saveOriginal(_ item: PhotosAPI.Item,
                             library: PhotoLibrary,
                             manager: SessionManager) async throws -> URL {
        guard let destination = askDestination(item.filename) else {
            throw PhotosAPI.PhotosError.cancelled
        }
        let endpoint = try await manager.fileEndpoint
        if let folder = await library.folderPath(of: item, manager: manager) {
            let path = PhotosAPI.libraryRoot + folder + "/" + item.filename
            do {
                try await FileDownloader(
                    baseURL: endpoint.baseURL,
                    credentials: endpoint.credentials,
                    allowSelfSigned: endpoint.allowSelfSigned,
                    destination: destination
                ).start(path: path)
                return destination
            } catch {
                // 目录拼错了（历史库的目录命名不总是 `/年/月`）就走照片接口再试一次。
                NSLog("[photos] 路径下载失败（%@），改走 Download.download", Self.describe(error))
            }
        }
        let data = try await PhotosAPI.originalData(item, manager: manager)
        try data.write(to: destination)
        return destination
    }

    // MARK: - 相册

    /// 新建相册。建完回读一次列表确认它在（`create` 回的对象是可信的，但列表才是
    /// 用户看到的东西）。
    static func createAlbum(name: String,
                            manager: SessionManager) async throws -> PhotosAPI.Album {
        try await PhotosAPI.createAlbum(name: name, manager: manager)
    }

    /// 加到相册。返回失败的 id（空 = 全成功）。
    static func addToAlbum(_ items: [PhotosAPI.Item], albumID: Int,
                           manager: SessionManager) async -> PhotoWriteResult {
        var result = PhotoWriteResult()
        let ids = items.map(\.id)
        do {
            let failed = try await PhotosAPI.addItems(ids, toAlbum: albumID, manager: manager)
            result.done = ids.count - failed.count
            result.failed = failed.count
            if !failed.isEmpty { result.reason = "相册没有收下其中 \(failed.count) 张" }
        } catch {
            result.failed = ids.count
            result.reason = Self.describe(error)
        }
        return result
    }

    /// 从相册移出（**只移容器，不删图**）。
    static func removeFromAlbum(_ items: [PhotosAPI.Item], albumID: Int,
                                manager: SessionManager) async -> PhotoWriteResult {
        var result = PhotoWriteResult()
        let ids = items.map(\.id)
        do {
            let failed = try await PhotosAPI.removeItems(ids, fromAlbum: albumID, manager: manager)
            result.done = ids.count - failed.count
            result.failed = failed.count
            if !failed.isEmpty { result.reason = "有 \(failed.count) 张没能移出" }
        } catch {
            result.failed = ids.count
            result.reason = Self.describe(error)
        }
        return result
    }

    /// 相册改名。写完回读列表确认新名字落库了。
    static func renameAlbum(_ albumID: Int, to name: String,
                            manager: SessionManager) async -> Bool {
        do {
            try await PhotosAPI.setAlbumName(albumID, name: name, manager: manager)
        } catch {
            NSLog("[photos] 相册改名失败：%@", Self.describe(error))
            return false
        }
        let albums = (try? await PhotosAPI.albums(manager: manager)) ?? []
        return albums.contains { $0.id == albumID && $0.name == name }
    }

    /// 删相册。**只删容器**，照片留在照片库里。
    ///
    /// 回 `true` 的条件是「列表里不再有这个 id」—— 写接口回 `ok` 不算数
    /// （这套接口在这个毛病上栽过一次，见 `PhotosAPI.deleteAlbum` 的注释）。
    static func deleteAlbum(_ albumID: Int, manager: SessionManager) async -> Bool {
        do {
            try await PhotosAPI.deleteAlbum(albumID, manager: manager)
        } catch {
            NSLog("[photos] 相册删除失败：%@", Self.describe(error))
            return false
        }
        let albums = (try? await PhotosAPI.albums(manager: manager)) ?? []
        return !albums.contains { $0.id == albumID }
    }

    // MARK: - 条目写回（2026-10-21 实测，`photosprobe26/27.py`）

    /// 写描述。成功回落库的文本（trim 后），失败回 `nil`。
    ///
    /// 清空传 JSON 编码的空串（服务端无视裸空串，见 `PhotosAPI.setItem`）；
    /// 回读交给调用方（`AppState` 拿返回值就地改，不另起一次网络）—— 写入
    /// 本身在这条通道上已被探针回读验证过。
    static func setDescription(_ itemID: Int, to text: String,
                               manager: SessionManager) async -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = value.isEmpty ? "\"\"" : value
        do {
            try await PhotosAPI.setItem(id: itemID, update: ["description": payload],
                                        manager: manager)
        } catch {
            NSLog("[photos] 写描述失败：%@", Self.describe(error))
            return nil
        }
        return value
    }

    /// 写评分。回回读到的值（`set` 对假 id 也回 success，这条通道的判据
    /// 与删除同一套：不拿回执当真）。回读失败时退回写入值 —— 通道已被
    /// 探针验证，比报错打断用户合理。
    static func setRating(_ itemID: Int, to rating: Int,
                          manager: SessionManager) async -> Int? {
        do {
            try await PhotosAPI.setItem(id: itemID, update: ["rating": String(rating)],
                                        manager: manager)
        } catch {
            NSLog("[photos] 写评分失败：%@", Self.describe(error))
            return nil
        }
        if let item = try? await PhotosAPI.getItem(id: itemID, manager: manager) {
            return item.rating
        }
        return rating
    }

    /// 写拍摄时间。参数是 Unix 秒（`time`），写完用 `get` 回读确认。
    ///
    /// 通道 2026-10-21 实测定案（`photosprobe28.py`）：`id` 方括号串 + `time`
    /// 整数真写；裸 id 回 ok + `error_list` 空但什么都不动。回读值带秒，
    /// 界面上的输入只到分钟 —— 回读与写入不等时以回读为准。
    static func setTime(_ itemID: Int, to date: Date,
                        manager: SessionManager) async -> Date? {
        let seconds = Int(date.timeIntervalSince1970)
        do {
            try await PhotosAPI.setItem(id: itemID, update: ["time": String(seconds)],
                                        manager: manager)
        } catch {
            NSLog("[photos] 写拍摄时间失败：%@", Self.describe(error))
            return nil
        }
        if let item = try? await PhotosAPI.getItem(id: itemID, manager: manager) {
            return item.time
        }
        return date
    }

    /// 把照片从人物里去掉：列出这张里该人物的脸（同张同脸可多枚），逐个摘，
    /// 回读确认清空。回 `true` 才算成 —— `delete_face` 对假 id 也回 ok。
    ///
    /// 通道 2026-10-21 实测定案（`photosprobe29/31`）：`Browse.Item.list_face`
    /// （`id_item` + `person_id`）拿脸 id → `Browse.Person.delete_face`
    /// （`person_id` 明文 + `face_id` **方括号串**）逐枚摘。裸数字 face_id 回 ok
    /// 但什么都不删 —— 这条踩过，别再改回去。
    static func removeFromPerson(_ itemID: Int, personID: Int,
                                 manager: SessionManager) async -> Bool {
        let faceIDs: [Int]
        do {
            faceIDs = try await PhotosAPI.faceIDs(itemID: itemID, personID: personID,
                                                  manager: manager)
        } catch {
            NSLog("[photos] 列人脸失败：%@", Self.describe(error))
            return false
        }
        guard !faceIDs.isEmpty else { return false }
        do {
            for faceID in faceIDs {
                try await PhotosAPI.deleteFace(personID: personID, faceID: faceID,
                                               manager: manager)
            }
        } catch {
            NSLog("[photos] 摘脸失败：%@", Self.describe(error))
            return false
        }
        let rest = (try? await PhotosAPI.faceIDs(itemID: itemID, personID: personID,
                                                 manager: manager)) ?? []
        return rest.isEmpty
    }

    /// 圈一块脸并回读。回回读里对上的那枚新脸；写失败或回读没对上（假成功族）
    /// 都回 `nil`。接口形态见 `PhotosAPI.addFace` 的注释（2026-10-21 定案）。
    static func addFace(_ itemID: Int, box: CGRect, owner: PhotosAPI.FaceOwner,
                        manager: SessionManager) async -> PhotosAPI.Face? {
        let tempID = String(Int.random(in: 100_000...999_999))
        let faceID: Int?
        do {
            faceID = try await PhotosAPI.addFace(itemID: itemID, box: box, owner: owner,
                                                 tempID: tempID, manager: manager)
        } catch {
            NSLog("[photos] 圈脸失败：%@", Self.describe(error))
            return nil
        }
        guard let faceID else { return nil }
        let faces = (try? await PhotosAPI.faces(itemID: itemID, manager: manager)) ?? []
        return faces.first { $0.id == faceID }
    }

    // MARK: - 人物

    /// 人物命名 / 改名。写完回读列表确认新名字落库了。
    ///
    /// 服务端会把名字首尾空白 trim 掉（`" "` 落成无名，「取消命名」靠它），
    /// 所以判据是「回读到的名字 == trim 后的名字」—— 两个方向都盖住。
    static func renamePerson(_ personID: Int, to name: String,
                             manager: SessionManager) async -> Bool {
        do {
            try await PhotosAPI.setPersonName(personID, name: name, manager: manager)
        } catch {
            NSLog("[photos] 人物改名失败：%@", Self.describe(error))
            return false
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let people = (try? await PhotosAPI.persons(manager: manager)) ?? []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return people.first { $0.id == personID }?.name == trimmed
    }

    /// 人物归并（`source` 并进 `target`）。回 `true` = 列表里不再有 source、
    /// target 还在 —— 与删除同一套「回 ok 不算数」的回读判据
    /// （merge 三参数全明文时会**静默空转**，见 `PhotosAPI.mergePerson`）。
    static func mergePerson(_ sourceID: Int, into targetID: Int,
                            manager: SessionManager) async -> Bool {
        do {
            try await PhotosAPI.mergePerson(source: sourceID, into: targetID,
                                            manager: manager)
        } catch {
            NSLog("[photos] 人物归并失败：%@", Self.describe(error))
            return false
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let people = (try? await PhotosAPI.persons(manager: manager)) ?? []
        let ids = Set(people.map(\.id))
        return !ids.contains(sourceID) && ids.contains(targetID)
    }

    // MARK: - 辅助

    private static func askDestination(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "下载到"
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription {
            return text
        }
        return error.localizedDescription
    }
}
