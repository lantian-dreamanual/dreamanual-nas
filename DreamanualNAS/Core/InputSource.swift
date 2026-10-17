import Carbon

/// 输入源：要半角 ASCII 的字段（口令 / 账号 / QuickConnect ID）拿到焦点时，
/// 程序把输入法切到 ASCII 布局，离开字段还原成用户原来那个。
///
/// 为什么不让用户自己切：中文输入法下按 `!` 得到的是全角「！」（U+FF01），
/// 长度一样、内容差一位，登录只回「账号或口令不对」—— 用户无从看出差别
/// （2026-10-17 真机踩过，卡了两轮）。进字段就切，把这类错误挡在产生之前。
///
/// 边界：只在焦点期间生效，离开立刻还原，不替用户改系统默认输入法；
/// 已经是 ASCII 时什么都不做（否则会把「还原目标」记成 ASCII，用户的中文
/// 输入法就真丢了）。
@MainActor
enum InputSource {
    /// 切到 ASCII 之前的那一个。嵌套进入（口令 → 账号）只记最外层那次。
    private static var restoreTarget: TISInputSource?

    @discardableResult
    static func enterASCII() -> Bool {
        guard let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue()
        else { return false }
        if identifier(of: ascii) == currentIdentifier() { return false }
        if restoreTarget == nil {
            restoreTarget = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        }
        return TISSelectInputSource(ascii) == noErr
    }

    static func restore() {
        guard let target = restoreTarget else { return }
        TISSelectInputSource(target)
        restoreTarget = nil
    }

    /// 当前输入源的标识（`com.apple.keylayout.ABC` 之类），诊断与冒烟用。
    static func currentIdentifier() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        else { return "" }
        return identifier(of: source)
    }

    private static func identifier(of source: TISInputSource) -> String {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// `DM_INPUT=switch`：切一次、保持 2 秒、再还原 —— 验证这条调用在 app 里
    /// 真的生效（AI 点不了输入框，焦点那半只能由用户点验；「保持 2 秒」是为了
    /// 让外部进程在这段时间里独立读到当前输入源）。
    static func smoke() async {
        // 等窗口与激活状态落定：启动瞬间读到的输入源不可靠（实测会报 ABC）。
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        NSLog("[input] 起始 %@", currentIdentifier())
        NSLog("[input] enterASCII switched=%d", enterASCII() ? 1 : 0)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        NSLog("[input] 持有时 %@", currentIdentifier())
        restore()
        try? await Task.sleep(nanoseconds: 600_000_000)
        NSLog("[input] 还原后 %@", currentIdentifier())
    }
}
