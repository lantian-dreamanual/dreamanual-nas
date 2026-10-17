import Foundation

/// 口令存本机文件（0600），钥匙串退出日常路径。
///
/// 🔴 为什么不用钥匙串（2026-10-13 实测结论）：钥匙串条目的访问授权绑在
/// **请求方的代码签名身份**上。开发期 ad-hoc 签名每次重编译都变，macOS 就
/// 当成新 app，用户每次都得再点一次授权框；`-A`（允许任意应用）在这台
/// macOS 上实测不生效（用另编译的独立程序读带 `-A` 的条目照样弹）。
/// 文件方案与「`-A` 钥匙串」的防护级别等价 —— 都是同机同用户可读；
/// 代价说明白：明文文件，靠 0600 权限 + FileVault 兜着。
///
/// 迁移：已于 2026-10-17 下线。原设计「文件不存在时读一次钥匙串」，但
/// 钥匙串授权绑签名身份，ad-hoc 重编译后每次都弹授权框；而且只要文件
/// 一时读不到（比如被临时移开），就会撞上弹框阻塞加载线程。文件方案
/// 落地以来口令都已迁移完，这条路径只剩制造弹框 —— 彻底移除。
///
/// 位置：`~/Library/Application Support/DreamanualNAS/credential.json`
/// （目录 0700、文件 0600；键用「端点|用户名」，与 `endpointKey` 同一套）。
enum CredentialStore {
    static var fileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DreamanualNAS/credential.json")
    }

    static func accountKey(endpointID: String, username: String) -> String {
        "\(endpointID)|\(username)"
    }

    private static func stored() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    /// 只读文件。没有就是没有 —— 绝不碰钥匙串（见类型注释）。
    ///
    /// 端点键取不到时按账号回退：端点键区分的是「怎么连到这台 NAS」
    /// （QuickConnect ID / 直连地址），账号口令是同一个。不这么做的话，
    /// 换个线路（设置页填直连地址、或地址改了个端口）就得把口令再输一遍。
    /// 同一账号存在多条**内容不同**的记录时才放弃 —— 那说明可能是两台
    /// NAS 共用账号，猜错口令会把 DSM 的自动封锁喂起来。
    static func load(endpointID: String, username: String) -> String? {
        let dict = stored()
        let key = accountKey(endpointID: endpointID, username: username)
        if let value = dict[key], !value.isEmpty { return value }
        // 裸账号键兜底：钥匙串时代用户在终端里存过的那种写法，文件里也认。
        if let value = dict[username], !value.isEmpty { return value }
        guard !username.isEmpty else { return nil }
        let sameAccount = dict
            .filter { $0.key.hasSuffix("|\(username)") && !$0.value.isEmpty }
            .map(\.value)
        let distinct = Set(sameAccount)
        if distinct.count == 1 { return distinct.first }
        if distinct.count > 1 {
            NSLog("[credential] 账号 %@ 有 %d 条不同口令，端点键 %@ 取不到，不猜",
                  username, distinct.count, endpointID)
        }
        return nil
    }

    @discardableResult
    static func save(password: String, endpointID: String, username: String) -> Bool {
        var dict = stored()
        dict[accountKey(endpointID: endpointID, username: username)] = password
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(dict)
            try data.write(to: url, options: [.atomic])
            // 原子写会新建文件，权限要在写完之后补 —— 口令文件只给本人读。
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("[credential] 写入口令文件失败：%@", String(describing: error))
            return false
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
