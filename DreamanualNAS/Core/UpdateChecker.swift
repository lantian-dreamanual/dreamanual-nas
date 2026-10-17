import Foundation
import Observation

/// 版本信息：官网 JSON 与 GitHub Releases 两个源解析成同一份结构。
struct UpdateInfo: Codable {
    let version: String
    let notes: String?
    let downloadUrl: String
    let releaseUrl: String?

    enum CodingKeys: String, CodingKey {
        case version
        case notes
        case downloadUrl = "download_url"
        case releaseUrl = "release_url"
    }
}

/// 检查更新：官网 `nas-version.json` 主源、GitHub Releases 兜底 —— 与投资监控、
/// 密码管理同一条路（发版只改服务器上的 JSON，不改客户端）。
///
/// 只在设置页手动触发，不做启动自动检查：本 app 没有横幅位，自动查出来的结果
/// 无处可显示，等于白花一次请求。将来要加自动检查，就在入口 `.task` 里调
/// `checkForUpdate()`，再把 `status == .newVersion` 接到 Toast 上。
@MainActor
@Observable
final class UpdateChecker {
    /// 手动检查的反馈状态（设置页那一行用）。
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case newVersion
        case failed

        /// 行尾状态文案。`idle` 与 `checking` 另有处理（idle 不显示、checking 直接给字）。
        var text: String {
            switch self {
            case .idle: return ""
            case .checking: return "检查中…"
            case .upToDate: return "已是最新版本"
            case .newVersion: return "发现新版本"
            case .failed: return "检查失败，稍后再试"
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var available: UpdateInfo?

    /// 当前版本号：读 Bundle（发版只改 Info.plist）。
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    /// 两个源的地址与下载链接都是常量，发版不动代码。
    static let versionURL = "https://dreamanual.com/works/downloads/nas-version.json"
    static let githubAPIURL = "https://api.github.com/repos/lantian-dreamanual/dreamanual-nas/releases/latest"
    static let githubReleasePage = "https://github.com/lantian-dreamanual/dreamanual-nas/releases"
    /// 官网下载地址：发版前先指应用主页（版本 JSON 里没给 `download_url` 时的兜底）。
    static let downloadPageURL = "https://dreamanual.com/works/nas.html"

    var isChecking: Bool { status == .checking }

    /// 设置页「立即检查」：不受任何开关限制，每次都给结果。
    func check() async {
        guard status != .checking else { return }
        status = .checking
        available = nil

        if let info = await fetch(from: Self.versionURL, isGitHub: false) {
            finish(with: info)
            return
        }
        if let info = await fetch(from: Self.githubAPIURL, isGitHub: true) {
            finish(with: info)
            return
        }
        status = .failed
    }

    /// 新版本被发现后，按钮变成「下载更新」—— 走 JSON 里的 `download_url`，
    /// 没给就回退到官网应用页（宁可多一次点击，也不给一个 404 的直链）。
    var downloadURL: URL? {
        URL(string: available?.downloadUrl ?? Self.downloadPageURL)
    }

    // MARK: - 取数与判定

    private func finish(with info: UpdateInfo) {
        guard isNewer(info.version, than: currentVersion) else {
            status = .upToDate
            return
        }
        available = info
        status = .newVersion
    }

    private func fetch(from urlString: String, isGitHub: Bool) async -> UpdateInfo? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("DreamanualNASAssistant/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if isGitHub {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if isGitHub {
                // tag_name 形如 v1.1.0，去掉前缀 v；下载落 GitHub Releases 页
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else { return nil }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                return UpdateInfo(version: version,
                                  notes: json["body"] as? String,
                                  downloadUrl: Self.githubReleasePage,
                                  releaseUrl: Self.githubReleasePage)
            }
            return try JSONDecoder().decode(UpdateInfo.self, from: data)
        } catch {
            return nil
        }
    }

    /// 语义化版本比较：a 比 b 新才 true（缺的段按 0 算）。
    private func isNewer(_ a: String, than b: String) -> Bool {
        let left = a.split(separator: ".").compactMap { Int($0) }
        let right = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(left.count, right.count) {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
