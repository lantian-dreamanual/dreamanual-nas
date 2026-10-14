import Foundation
import Observation

/// 复制 / 移动这一批的批次状态：模式、来源、撞名判定与进行中标记。
///
/// 与 `UploadQueue` 同一层：**只放状态与规则**，真正的接口调用与 Toast 留在
/// `AppState`（与新建 / 改名 / 删除同构）。目标选择器是它的一块（`picker`）。
@MainActor
@Observable
final class FileTransfer {
    enum Mode: Equatable {
        case copy
        case move

        var title: String { self == .copy ? "复制到…" : "移动到…" }
        /// 弹窗脚上那个确认按钮。
        var confirmTitle: String { self == .copy ? "复制到此处" : "移动到此处" }
        var icon: String { self == .copy ? "copy" : "folder-input" }
        /// 跑完 Toast 里的动词。
        var verb: String { self == .copy ? "复制" : "移动" }
    }

    /// 撞名怎么处理。**只有两选**。
    ///
    /// 「保留两者」做不了：接口**不能给新来的一份改名** —— `CopyMove` 的 `name` /
    /// `new_name` / `rename_to` 三个键 2026-10-14 实测全被忽略（复制过去仍是原名）。
    /// 换一条路是「先把目标处已有的那一项改名、再复制」，那会把「2」贴到用户原来的
    /// 文件上（上传那批是给新来的加「2」），做法不一致又擅自动了用户的文件，不做。
    ///
    /// 目录撞名另有服务端行为：无论哪个值**一律合并**（`overwrite` 只管文件），
    /// 所以对目录这两选实际是「合并 / 跳过」—— 跳过靠客户端不发这一项实现。
    enum ConflictChoice {
        case replace
        case skip
    }

    struct Conflict {
        let mode: Mode
        let destination: String
        /// 目标处已经有同名项的来源（数量和下面那份合起来就是全部来源）。
        let clashes: [FileEntry]
        /// 目标处没有同名项的来源，怎么选都要传。
        let clean: [FileEntry]
    }

    let picker = DestinationPicker()

    private(set) var mode: Mode?
    private(set) var sources: [FileEntry] = []
    /// 来源所在的目录（选中的条目都在这一层）。
    private(set) var sourceDirectory = ""
    private(set) var conflict: Conflict?
    /// 任务在跑 —— 工具条这两个入口暂时不接第二次。
    private(set) var isBusy = false

    var isOpen: Bool { mode != nil }

    func begin(_ mode: Mode, sources: [FileEntry], currentPath: String) {
        guard !sources.isEmpty else { return }
        self.mode = mode
        self.sources = sources
        sourceDirectory = currentPath
        conflict = nil
    }

    func cancel() {
        mode = nil
        sources = []
        conflict = nil
        picker.reset()
    }

    func clearConflict() { conflict = nil }

    func raiseConflict(_ conflict: Conflict) { self.conflict = conflict }

    func setBusy(_ value: Bool) { isBusy = value }

    // MARK: - 确认禁用

    /// 目标不能是哪儿。三条都属于「静默无操作」级别 —— 服务端要么什么都不做、
    /// 要么把错误藏进任务的 `errors`，界面上先拦住才说得清。
    ///
    /// 注意**来源目录不可写只挡「移动」**：复制是读来源、写目标，来源只读照样能复制。
    /// 这条判据在工具条与菜单那两处入口上（按钮灰 / 菜单项不出现），不在这里 ——
    /// 弹窗已经开了才发现进不来，白让用户走一趟。
    var blockingReason: String? {
        let target = picker.target
        guard !target.isEmpty else { return "先选一个目标目录。" }
        // 来源就在当前这一层，目标又是这一层 → 每一项的同名项就是它自己，服务端静默跳过
        // （2026-10-14 实测：任务 success、内容没动、连 `skipstatus` 都不带）。
        if target == sourceDirectory { return "目标就是来源所在的位置，换一个目录。" }
        // 目录挪进自己里面 → 任务报 `errors[{1003}]`。服务端会拦，界面先拦。
        if sources.contains(where: { $0.isDirectory && (target == $0.path || target.hasPrefix($0.path + "/")) }) {
            return "目标不能是来源自己，也不能在来源里面。"
        }
        if !picker.targetCanWrite { return "目标目录不可写，换一个位置。" }
        return nil
    }

    /// 确认按钮亮不亮。
    var canConfirm: Bool { mode != nil && !isBusy && blockingReason == nil }

    /// 撞名弹窗里那句「N 项」。
    var sourceCount: Int { sources.count }
}
