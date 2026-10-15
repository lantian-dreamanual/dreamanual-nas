import Foundation

/// 取流 / 下载那一路共用的「主机 + 凭据 + 证书策略」三件套。
///
/// 原本嵌在 `StreamLoader` 里；小组件 target 只用得到 SessionManager（它
/// 引用这个类型），用不到 AVPlayer 那一整套 —— 所以提升为顶层类型，widget
/// 编它、不编 StreamLoader 本体（本体拖着 AudioSong / AVFoundation）。
/// `StreamLoader` 里留了 typealias 保持原写法可用。
struct StreamEndpoint: @unchecked Sendable {
    /// `https://<主机>:<端口>/webapi/`
    let baseURL: URL
    let credentials: SynologyCredentials
    let allowSelfSigned: Bool
}
