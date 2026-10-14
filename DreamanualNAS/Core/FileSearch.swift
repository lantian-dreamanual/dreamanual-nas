import Foundation
import Observation

/// 文件管理页的搜索（走服务端的 `FileStation.Search`）。
///
/// 挂 `AppState` 而不是视图的 `@State` —— 与文件管理页、选目标弹窗同一个理由：
/// 换模块再回来不该把结果丢掉，冒烟通路也要能在视图之外把它摆到各个状态。
///
/// **为什么是「提交式」而不是「输入即筛」**：这条路的每一次搜索都要 2–9 秒
/// （服务端要遍历目录、还会随机返回假空让你重来）。输入即搜会把每个键都变成一次
/// 全库遍历。选目标弹窗那边能「输入即筛」是因为它筛的是**客户端已经拉下来的层**，
/// 一条请求都不发；这里没有那份现成数据。
///
/// 收尾：`Search` 的任务做完还在，**翻页要靠它**，所以不能在拿到结果时就 clean；
/// 收尾放在「清除搜索」与「下一次搜索开头」两处（`stop` + `clean`）。
@MainActor
@Observable
final class FileSearch {
    enum Phase: Equatable {
        /// 没在搜 —— 页面照旧显示当前目录的列表。
        case idle
        /// 正在搜。`attempt` 是已经用掉几次 `start`（假空重试）。
        case running
        /// 出结果了（真零也算）。
        case done
        /// 重试耗尽或真出错。`errorMessage` 说清是哪一种。
        case failed
    }

    /// 假空重试上限。实测假空是随机的：`接口结论.md` 记的平均 2.9 次，
    /// 2026-10-14 复测最坏连吃 **6 次**才出结果 → 上限取 12（每次假空只花约 1 秒）。
    static let attemptLimit = 12

    /// 一页拉多少 —— 与浏览列表同档（曲库也是一页 1000）。
    static let pageSize = FileBrowser.pageSize

    /// 搜索框里的字（`DmSearchField` 直接绑它）。
    var query = ""
    /// 这次搜的是哪个目录（范围 = 这个目录递归往下）。
    private(set) var folder = ""
    private(set) var phase: Phase = .idle
    /// 已经用掉几次 `start`。界面显示「第 N 次 / 上限 12 次」。
    private(set) var attempt = 0
    private(set) var hits: [FileSearchHit] = []
    /// 终值条数（轮询到 `finished` 之后服务端给的那个 `total`）。
    private(set) var total = 0
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?

    /// 服务端那个搜索任务。**做完不立刻收掉** —— 翻页还要用它。
    private var taskid = ""
    /// 每次搜索 / 取消都 +1；循环里拿本地那份比，对不上就退出。
    /// 用计数器而不是布尔量：连着搜两次时，布尔量会被后一次「取消掉」前一次的状态。
    private var generation = 0

    var isActive: Bool { phase != .idle }
    var hasMore: Bool { phase == .done && hits.count < total }
    var isRunning: Bool { phase == .running }

    /// 搜索进度行第二行那句话（原型画的「正在重试」是一等状态，不是错误）。
    var progressNote: String {
        if attempt <= 1 { return "在「\(folder)」里找「\(query)」" }
        return "服务端返回了空应答，正在重试（第 \(attempt) 次 / 上限 \(Self.attemptLimit) 次）"
    }

    /// 结果行的说明行（状态栏那一条）。
    var resultNote: String {
        switch phase {
        case .idle: return ""
        case .running: return "正在搜索…"
        case .failed: return errorMessage ?? "没能搜成"
        case .done:
            return total == 0 ? "没有匹配的项" : "找到 \(total) 条"
        }
    }

    // MARK: - 跑一次搜索

    /// 提交式入口：搜索框回车、或冒烟通路调它。
    ///
    /// `text` 空着就是「清除」—— `DmSearchField` 的清除钮也是走这一条（它清完字会
    /// 再调一次 `onSubmit`），所以这里把空串当退出搜索处理。
    func run(_ text: String, in folder: String, on manager: SessionManager?) async {
        guard let manager else { return }
        let keyword = text.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else {
            await clear(on: manager)
            return
        }
        // 上一轮的任务要收掉（stop + clean），否则服务端攒一堆。
        await releaseTask(manager)
        generation += 1
        let token = generation

        query = keyword
        self.folder = folder
        phase = .running
        attempt = 0
        hits = []
        total = 0
        errorMessage = nil

        while attempt < Self.attemptLimit {
            if token != generation { return }
            attempt += 1
            let id: String
            do {
                id = try await FileStation.searchStart(manager, folder: folder, pattern: keyword)
            } catch {
                guard token == generation else { return }
                phase = .failed
                errorMessage = error.localizedDescription
                return
            }
            taskid = id
            var settled = false
            while !settled {
                if token != generation { return }
                do {
                    let page = try await FileStation.searchPage(
                        manager, taskid: id, offset: 0, limit: Self.pageSize
                    )
                    if let found = page.total {
                        // 有 `total` 键就是真的拿到了 —— 不管 `finished` 是真是假，
                        // 终值要等 `finished = true`，过程值只用来显示「还在数」。
                        total = found
                        if page.finished {
                            hits = page.hits
                            phase = .done
                            settled = true
                        }
                    } else if page.isFakeEmpty {
                        // 🔴 假空：应答里连 `total` 键都没有。收掉这个任务重来。
                        await FileStation.searchStop(manager, taskid: id)
                        taskid = ""
                        settled = true
                    } else {
                        total = hits.count
                    }
                } catch {
                    guard token == generation else { return }
                    await FileStation.searchStop(manager, taskid: id)
                    taskid = ""
                    phase = .failed
                    errorMessage = error.localizedDescription
                    return
                }
                if !settled { try? await Task.sleep(nanoseconds: 400_000_000) }
            }
            if phase == .done { return }
        }
        phase = .failed
        errorMessage = "服务端连着 \(Self.attemptLimit) 次返回空应答，这次没搜成。"
    }

    /// 接着拉下一页。任务还活着，所以直接按偏移取。
    func loadMore(on manager: SessionManager?) async {
        guard hasMore, !isLoadingMore, !taskid.isEmpty, let manager else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await FileStation.searchPage(
                manager, taskid: taskid, offset: hits.count, limit: Self.pageSize
            )
            hits += page.hits
            if let found = page.total { total = found }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 用户按「停止」：收掉服务端任务、回浏览态。
    func cancel(on manager: SessionManager?) async {
        generation += 1
        await releaseTask(manager)
        reset()
    }

    /// 「清除」/ 退出搜索：与服务端断开、回浏览态。
    func clear(on manager: SessionManager?) async {
        generation += 1
        await releaseTask(manager)
        reset()
    }

    /// 收掉服务端那个搜索任务（`stop` 之后 `clean`，把结果一起清掉）。
    private func releaseTask(_ manager: SessionManager?) async {
        guard let manager, !taskid.isEmpty else { return }
        let id = taskid
        taskid = ""
        await FileStation.searchStop(manager, taskid: id)
        await FileStation.searchClean(manager, taskid: id)
    }

    private func reset() {
        query = ""
        phase = .idle
        attempt = 0
        hits = []
        total = 0
        errorMessage = nil
    }
}
