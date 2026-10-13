// 封面取图自检（只读）。
//
// 为什么单独拎一个工具：封面串台是**数据层**的现象（同名专辑被 DSM 并成一张），
// 界面上要滚到那几行才看得见，而 AI 点不了界面。这个工具直接把库里同名的专辑
// 逐条取一遍、打字节数与 md5 —— 三张同名专辑拿到三个不同的 md5，就是修好了。
//
// 跑法（编译整份源码，去掉 @main 入口）：
//   cd apps/nas && bash -c 'FILES=$(find DreamanualNAS -name "*.swift" ! -name "DreamanualNASApp.swift");
//     xcrun swiftc -disable-sandbox -o /tmp/cover-selfcheck $FILES tools/cover-selfcheck/main.swift' && /tmp/cover-selfcheck
//
// 参数：`--album <专辑名>` 指定要查的专辑名（默认 `0`，就是用户抓到串台的那张）。
// 口令从 `CredentialStore` 的本机文件读，端点从文件里的键解析（`qc:<ID>` 走
// QuickConnect、`direct:<host>:<port>` 直连）。

import CryptoKit
import Foundation

let arguments = CommandLine.arguments
var albumName = "0"
var highRes = false
if let index = arguments.firstIndex(of: "--album"), index + 1 < arguments.count {
    albumName = arguments[index + 1]
}
if arguments.contains("--high-res") { highRes = true }

func md5Short(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).prefix(5).map { String(format: "%02x", $0) }.joined()
}

func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

// MARK: 端点与凭据

let stored = (try? Data(contentsOf: CredentialStore.fileURL))
    .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
guard let entry = stored.first(where: { $0.key.contains("|") }) else {
    log("凭据文件里没有「端点|用户名」这样的键，先在 app 里连一次。")
    exit(1)
}
let parts = entry.key.split(separator: "|", maxSplits: 1).map(String.init)
let endpointID = parts[0]
let username = parts.count > 1 ? parts[1] : parts[0]
let password = entry.value

log("端点标识 \(endpointID) · 账号 \(username) · 专辑名「\(albumName)」· \(highRes ? "原图" : "缩略图")")

func makeClient() async throws -> SynologyClient {
    if endpointID.hasPrefix("direct:") {
        let rest = endpointID.dropFirst("direct:".count)
        let bits = rest.split(separator: ":")
        let host = String(bits[0])
        let port = bits.count > 1 ? Int(bits[1]) ?? 5001 : 5001
        return SynologyClient(host: host, port: port, allowSelfSigned: true)
    }
    let qc = endpointID.hasPrefix("qc:") ? String(endpointID.dropFirst(3)) : endpointID
    let endpoint = try await QuickConnectResolver().resolve(id: qc)
    return SynologyClient(host: endpoint.host, port: endpoint.port, allowSelfSigned: false)
}

// MARK: 查同名专辑下的每一首

let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    do {
        let client = try await makeClient()
        let manager = SessionManager(client: client, account: username, password: password)
        try await manager.probe()

        let page = try await AudioLibrary.search(manager, keyword: albumName, limit: 400)
        let hits = page.songs.filter { $0.album == albumName }
        log("匹配到专辑名「\(albumName)」的歌 \(hits.count) 首")

        var seenFolders = Set<String>()
        for song in hits {
            let folder = song.folder
            let folderTag = seenFolders.insert(folder).inserted ? "首次" : "同目录"
            let folderData = try? await AudioLibrary.folderCover(manager, folder: folder, highRes: highRes)
            log(String(
                format: "  %@ / %@  →  目录 %d 字节 md5 %@  (%@)",
                song.title, song.artist,
                folderData?.count ?? 0,
                folderData.map(md5Short) ?? "-",
                folderTag
            ))
        }

        log("---- 对照：按专辑名问 Audio Station（旧路） ----")
        var seenArtists = Set<String>()
        for song in hits where seenArtists.insert(song.albumArtist).inserted {
            let data = try? await AudioLibrary.cover(manager, album: song.album, artist: song.albumArtist)
            log(String(
                format: "  album_artist=%@  →  %d 字节 md5 %@",
                song.albumArtist.isEmpty ? "(空)" : song.albumArtist,
                data?.count ?? 0,
                data.map(md5Short) ?? "-"
            ))
        }

        log("---- 对照：走 app 同一条路（CoverStore，含缓存）----")
        for song in hits {
            let data = await CoverStore.shared.cover(
                manager: manager, album: song.album, artist: song.albumArtist,
                folder: song.folder, highRes: highRes
            )
            log(String(format: "  %@  →  %d 字节 md5 %@",
                       song.title, data?.count ?? 0, data.map(md5Short) ?? "-"))
        }
    } catch {
        log("失败：\(error.localizedDescription)")
        exit(2)
    }
}
semaphore.wait()
