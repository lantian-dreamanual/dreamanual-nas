import Foundation

// ============ 立刻关机 / 重启（模块三写半的最后一块） ============

/// `SYNO.Core.System` v1 的 `shutdown` / `reboot`（v2 同样有，v3 只剩 `info`，
/// `docs/接口结论.md` 第二节）。
///
/// 🔴 请求**不带任何额外参数** —— 探针（`shuffle-lab/powerprobe.py`，2026-10-17）
/// 假 sid 探得方法存在于 v1：回 119 会话错误而非 103「没这方法」，带真会话即执行。
/// 🔴 成功应答只有 `success: true`，**没有回读这一步** —— NAS 收了指令就开始下电，
/// 「服务端那一份」在这里天然不存在；判据只能是「没抛错」，指令发出后的真假交给
/// 链路监控（掉线转离线）与重启等待重连（约 2 分钟后自动补连）接盘。
enum SystemPowerAPI {
    enum Action: String {
        case shutdown
        case reboot

        /// 界面与提示条上的字。
        var label: String {
            switch self {
            case .shutdown: return "关机"
            case .reboot: return "重启"
            }
        }
    }

    @discardableResult
    static func power(_ action: Action, on manager: SessionManager) async throws -> Bool {
        _ = try await manager.call(
            kind: .file, api: "SYNO.Core.System", version: 1, method: action.rawValue
        )
        return true
    }
}
