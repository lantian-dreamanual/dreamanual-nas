import Foundation

/// QuickConnect 端点解析：拿 QC ID 换一个可用的中继端点。
///
/// 端点会变（中继 IP、端口、`relay_dn` 都是每次问出来的），所以**每次启动
/// 重新解析一遍**，不写死、不缓存到磁盘。见 docs/接口结论.md 第五节。
struct QCEndpoint: Equatable {
    /// 中继主机名（`relay_dn`）。域名写法不用关证书校验 —— 中继挂的是
    /// Let's Encrypt 真证书，`SAN=*.<QC-ID>.direct.quickconnect.cn`。
    let host: String
    let port: Int
    /// 中继区域（境内是 `cn4` / `cn`），只用于界面显示。
    let region: String?
    /// 局域网地址，局域网下可直接用它走直连。
    let lanIPs: [String]
    let externalIP: String?
}

enum QuickConnectError: LocalizedError {
    /// `errno: 4` + `suberrno: 1`，`errinfo: Alias not found`。
    case aliasNotFound
    case serverError(errno: Int, info: String)
    case badResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .aliasNotFound:
            return "找不到这个 QuickConnect ID：确认拼写，并确认 NAS 的控制面板里 QuickConnect 是开启状态。"
        case let .serverError(errno, info):
            return "QuickConnect 服务返回错误（\(errno)）：\(info)"
        case let .badResponse(text):
            return "QuickConnect 返回了看不懂的内容：\(text)"
        case let .network(text):
            return "连不上 QuickConnect 服务：\(text)"
        }
    }
}

struct QuickConnectResolver {
    static let servURL = URL(string: "https://global.quickconnect.cn/Serv.php")!

    /// 解析 QC ID。公开接口，不需要账号口令。
    ///
    /// 🔴 请求体是**数组**、且 `id` 是服务名 `mainapp_https`、QC ID 放 `serverID`
    /// —— 2026-10-12 实测：这版回 `errno 4 / Alias not found`（正确语义），
    /// 而「对象 + `svc` + `id` 放 QC ID」那版回 `errno 9` 且 `errinfo` 为空。
    func resolve(id: String) async throws -> QCEndpoint {
        var request = URLRequest(url: Self.servURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [[String: Any]] = [[
            "version": 1,
            "command": "get_server_info",
            "stop_when_error": false,
            "stop_when_success": false,
            "id": "mainapp_https",
            "serverID": id,
            "is_gofile": false,
            "path": "",
        ]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QuickConnectError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw QuickConnectError.network("HTTP \(http.statusCode)")
        }

        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first
        else {
            throw QuickConnectError.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        // 🔴 成功应答里也带 `errno: 0` —— 不能「见 errno 就当失败」，只判非零。
        if let errno = first["errno"] as? Int, errno != 0 {
            let info = (first["errinfo"] as? String) ?? ""
            if errno == 4 { throw QuickConnectError.aliasNotFound }
            throw QuickConnectError.serverError(errno: errno, info: info)
        }

        let service = (first["service"] as? [String: Any]) ?? [:]
        let env = (first["env"] as? [String: Any]) ?? [:]
        let server = (first["server"] as? [String: Any]) ?? [:]

        guard let host = service["relay_dn"] as? String, !host.isEmpty,
              let port = intValue(service["relay_port"])
        else {
            throw QuickConnectError.badResponse("没有 relay_dn / relay_port：\(first.keys.sorted())")
        }

        var lanIPs: [String] = []
        if let interfaces = server["interface"] as? [[String: Any]] {
            lanIPs = interfaces.compactMap { $0["ip"] as? String }
        }
        return QCEndpoint(
            host: host,
            port: port,
            region: env["relay_region"] as? String,
            lanIPs: lanIPs,
            externalIP: (server["external"] as? [String: Any])?["ip"] as? String
        )
    }

    /// `relay_port` 实测给的是数字，但 JSON 里也可能落成字符串 —— 两种都收。
    private func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
