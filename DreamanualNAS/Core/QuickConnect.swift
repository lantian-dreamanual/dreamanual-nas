import Foundation

/// QuickConnect 端点解析：拿 QC ID 换一个可用的中继端点。
///
/// 端点会变（中继域名、端口中继都是每次问出来的），所以**每次启动重新解析
/// 一遍**，不写死、不缓存到磁盘。
///
/// 🔴 **2026-10-16 服务端改版**：`get_server_info` 的 `service` 里不再有
/// `relay_dn` / `relay_port`，只剩 `port` / `ext_port` / `pingpong`，另加一个
/// `smartdns` 块（`<QC-ID>.direct.quickconnect.cn` 智能域名，主域名在公网
/// DNS 上是 NXDOMAIN，只有它自己的权威 NS + 客户端所在网段才解析得出）。
/// 中继端点要**单独发 `request_tunnel`** 才给 —— 实测它的 `service` 里
/// `relay_dn` / `relay_port` / `relay_ip` / `https_ip` 齐全，且对不存在的
/// QC ID 同样回 `errno 4 / Alias not found`，所以这一趟是唯一必需的一趟。
struct QCEndpoint: Equatable {
    /// 中继主机。优先 `relay_dn` 域名：它 CNAME 到 `cnrds4.re.cs.quickconnect.cn`，
    /// 证书按那个名字签，默认校验就能过。拿不到域名才退回 `relay_ip`。
    let host: String
    let port: Int
    /// 只有 IP、没有域名时为真 —— 域名对不上证书名字，连接要放行自签。
    let needsCertBypass: Bool
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
            return "连不上服务器：\(text)"
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
    /// `command` 取 `request_tunnel`：relay 端点只在这条命令的应答里给。
    func resolve(id: String) async throws -> QCEndpoint {
        var request = URLRequest(url: Self.servURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [[String: Any]] = [[
            "version": 1,
            "command": "request_tunnel",
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

        // 端口两种顺序都收：`relay_port` 是这台 NAS 专属的中继端口，`https_port`
        // （实测 443）不是这条业务 —— 打上去证书名字对不上，别拿它兜底。
        guard let port = intValue(service["relay_port"]) else {
            throw QuickConnectError.badResponse(
                "QuickConnect 没给出中继端口（`service` 里缺 `relay_port`）：\(service.keys.sorted())"
            )
        }
        let relayDN = (service["relay_dn"] as? String)?.trimmingCharacters(in: .whitespaces)
        let relayIP = (service["relay_ip"] as? String)?.trimmingCharacters(in: .whitespaces)
        let domain = (relayDN?.isEmpty == false) ? relayDN : nil
        guard let host = domain ?? (relayIP?.isEmpty == false ? relayIP : nil) else {
            throw QuickConnectError.badResponse(
                "QuickConnect 没给出中继地址（`service` 里缺 `relay_dn` / `relay_ip`）：\(service.keys.sorted())"
            )
        }

        var lanIPs: [String] = []
        if let interfaces = server["interface"] as? [[String: Any]] {
            lanIPs = interfaces.compactMap { $0["ip"] as? String }
        }
        return QCEndpoint(
            host: host,
            port: port,
            needsCertBypass: domain == nil,
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
