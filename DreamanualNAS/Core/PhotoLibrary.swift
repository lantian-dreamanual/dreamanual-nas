import Foundation
import Observation

/// 照片页的状态：全量拉条目、客户端按天分组、缩略图缓存。
///
/// 服务端的按天过滤已失灵（2026-10-20，Photos 1.9.1 起 `Browse.Item` 无视
/// `year` / `month` / `day`），所以条目**一次全量翻页取回、本地按天分组** ——
/// 天分组只由条目产生（一天有图才有组，不再有「骨架有、条目空」的天）。
@MainActor
@Observable
final class PhotoLibrary {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var days: [PhotosAPI.Day] = []
    /// 天 → 条目（服务端顺序：从新到旧）。分组完成后每一条都有组。
    private(set) var items: [String: [PhotosAPI.Item]] = [:]
    /// 加载中的已取条数，进度文案用。
    private(set) var loadedCount = 0
    /// 正在重拉。刷新不动已有内容，界面靠这个把刷新钮按下去。
    private(set) var isRefreshing = false

    /// 查看器当前显示哪一条。`nil` = 没开。挂在模型上而不是视图里 ——
    /// 覆盖层挂在窗口根（`RootView`），网格与它不在同一棵子树。
    var viewingID: Int?
    /// 查看器翻页走的那条序列。**不是恒为全库** —— 从人物 / 地点 / 标签 / 相册 /
    /// 搜索结果里点开的，就在那一份里前后翻（在「田泽昱的 1235 张」里点开一张，
    /// 往右翻应该是他的下一张，不是全库时间轴上的下一张）。
    private(set) var viewSequence: [PhotosAPI.Item] = []
    /// `position(of:)` 的计算结果按 id 缓存：摊平序列有一万条，顶栏每帧算一遍
    /// 日期分组不值得。
    @ObservationIgnored private var positionCache: (id: Int, index: Int, count: Int)?

    @ObservationIgnored private var thumbs: [Int: Data] = [:]
    @ObservationIgnored private var thumbOrder: [Int] = []
    @ObservationIgnored private var thumbFailures: Set<Int> = []
    @ObservationIgnored private var loadingThumbs: Set<Int> = []
    /// 刚上传那几张的本机小图：文件名 → 缩略图字节。
    ///
    /// 服务端是「文件落地 → 建立索引 → 生成缩略图」三步异步走，刚传完的几张在时间轴上
    /// 已经有条目、缩略图却还没生成，网格只能画灰块。本地文件是我们自己拿着的，现场
    /// 降采样一张顶上（群晖网页版能立刻看到图，靠的也是浏览器手里的原文件）。
    /// 服务端图生成好之后由 `sweepPendingThumbs` 换掉。
    @ObservationIgnored private var localPreviews: [String: Data] = [:]
    @ObservationIgnored private var previewOrder: [String] = []
    /// 本机预览换成服务端缩略图的次数，网格的 `.task(id:)` 跟着它重跑 ——
    /// `thumbs` 是 `@ObservationIgnored`，字典本身变了不会通知界面。
    private(set) var thumbRevision = 0
    /// 非条目封面的小图（人物头像、相册封面）：键是 `"p:<unit>"` / `"a:<album>"`。
    /// 与条目分两个字典 —— 两套 id 空间会撞。
    @ObservationIgnored private var auxThumbs: [String: Data] = [:]
    /// 条目目录（照片库内的相对路径）。同一目录下的几百张共用一次查询。
    @ObservationIgnored private var folderNames: [Int: String] = [:]
    @ObservationIgnored private var folderMisses: Set<Int> = []
    /// 查看器的大图（1280 长边）。只留最近几张 —— 原图尺寸的字节按张吃内存，
    /// 一路翻过去不能只增不减。
    @ObservationIgnored private var fulls: [Int: Data] = [:]
    @ObservationIgnored private var fullOrder: [Int] = []
    @ObservationIgnored private var loadingFulls: Set<Int> = []

    /// 缩略图缓存上限。真实家庭库几千张，不设上限会一路涨到几百 MB。
    private static let thumbLimit = 800
    private static let fullLimit = 8
    /// 本机预览的条数上限。一次拖几百张进来也不会无限涨（每张几十 KB）。
    private static let previewLimit = 300

    /// 每页条数。本机全库 10 154 条 ≈ 11 页；元数据每条几百字节，总量几 MB。
    private static let pageSize = 1000

    /// 页头副标题里的总数。
    var totalCount: Int { items.values.reduce(0) { $0 + $1.count } }

    var isReady: Bool { phase == .ready }

    /// 全部条目按天序摊平 —— 查看器的 `←` `→` 在这条线上走。
    var loadedItems: [PhotosAPI.Item] {
        days.flatMap { items[$0.id] ?? [] }
    }

    /// 查看器要显示的那一条。条目被重新载入时按 id 重新找，不持有旧引用。
    var viewingItem: PhotosAPI.Item? {
        guard let id = viewingID else { return nil }
        return viewSequence.first { $0.id == id } ?? loadedItems.first { $0.id == id }
    }

    /// 打开查看器。`sequence` 是这次要翻的那一份（缺省＝全库时间轴）。
    func openViewer(_ item: PhotosAPI.Item,
                    in sequence: [PhotosAPI.Item]? = nil) {
        let list = sequence ?? loadedItems
        viewSequence = list.isEmpty ? [item] : list
        positionCache = nil
        viewingID = item.id
    }

    func closeViewer() {
        viewingID = nil
        viewSequence = []
        positionCache = nil
    }

    // MARK: - 全量载入与分组

    func loadIfNeeded(_ manager: SessionManager?) async {
        if case .idle = phase { await load(manager) }
    }

    /// 全量重拉。**已有内容时不把网格换掉** —— 刷新是「再读一遍」，不是「重新开始」：
    /// 相位留在 `.ready`，界面上那几万张不动，读完一次性换成新分组。首屏（没有内容）
    /// 才进 `.loading`，那时本来也没东西可留。
    func load(_ manager: SessionManager?, force: Bool = false) async {
        guard let manager else { return }
        if case .loading = phase, !force { return }
        let hasContent = !days.isEmpty
        if !hasContent {
            phase = .loading
            loadedCount = 0
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var all: [PhotosAPI.Item] = []
            var offset = 0
            while true {
                let page = try await PhotosAPI.itemsPage(
                    offset: offset, limit: Self.pageSize, manager: manager)
                all.append(contentsOf: page)
                offset += page.count
                loadedCount = all.count
                if page.count < Self.pageSize { break }
            }
            group(all)
            phase = .ready
            NSLog("[photos] 全库 %d 条，%d 天", all.count, days.count)
        } catch {
            if hasContent {
                NSLog("[photos] 重拉失败，保留现有 %d 条：%@", totalCount, Self.describe(error))
            } else {
                phase = .failed(Self.describe(error))
            }
        }
    }

    /// 只取最新一页、按 id 增量并进现有分组，回并入的条数。
    ///
    /// 上传收尾走这条：全量重拉要翻十几页（本机一万张 ≈ 11 页），期间还把网格整个换成
    /// 「正在读取照片…」。这一页只覆盖服务端时间序最新的那些 —— 正常拍摄的照片都在里头；
    /// 补传的老照片落在时间轴中段，靠 `hasOrphanPreviews` 兜一次静默全量。
    @discardableResult
    func mergeRecent(_ manager: SessionManager?, limit: Int = 200) async -> Int {
        guard let manager else { return 0 }
        let page: [PhotosAPI.Item]
        do {
            page = try await PhotosAPI.itemsPage(offset: 0, limit: limit, manager: manager)
        } catch {
            NSLog("[photos] 增量重拉失败：%@", Self.describe(error))
            return 0
        }
        var known: Set<Int> = []
        for bucket in items.values { known.formUnion(bucket.map(\.id)) }
        let fresh = page.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        insert(fresh)
        NSLog("[photos] 增量并入 %d 条（最新一页 %d 条）", fresh.count, page.count)
        return fresh.count
    }

    /// 把一批新条目按天插进现有分组：新的一天插到它该在的位置，
    /// 已有的那一天把新条目排在前面（两段都是服务端的新→旧顺序）。
    private func insert(_ fresh: [PhotosAPI.Item]) {
        let calendar = PhotoDate.utcCalendar
        var byDay: [String: [PhotosAPI.Item]] = [:]
        var dayOf: [String: PhotosAPI.Day] = [:]
        for item in fresh {
            let c = calendar.dateComponents([.year, .month, .day], from: item.time)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let day = PhotosAPI.Day(year: y, month: m, day: d)
            byDay[day.id, default: []].append(item)
            dayOf[day.id] = day
        }
        for (id, incoming) in byDay {
            guard let day = dayOf[id] else { continue }
            if let existing = items[id] {
                items[id] = incoming + existing
            } else {
                items[id] = incoming
                let index = days.firstIndex { Self.isOlder($0, than: day) } ?? days.count
                days.insert(day, at: index)
            }
        }
    }

    /// `a` 是否比 `b` 旧（天序是新的在前）。
    private static func isOlder(_ a: PhotosAPI.Day, than b: PhotosAPI.Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// 按天分组（UTC 墙钟，口径见 `PhotoDate`）。服务端从新到旧给，按首次出现
    /// 顺序得天序；一天内的条目保持服务端顺序。
    private func group(_ all: [PhotosAPI.Item]) {
        var buckets: [String: [PhotosAPI.Item]] = [:]
        var order: [PhotosAPI.Day] = []
        var seen: Set<String> = []
        for item in all {
            let c = PhotoDate.utcCalendar.dateComponents([.year, .month, .day], from: item.time)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let day = PhotosAPI.Day(year: y, month: m, day: d)
            if seen.insert(day.id).inserted {
                order.append(day)
                buckets[day.id] = []
            }
            buckets[day.id]!.append(item)
        }
        days = order
        items = buckets
    }

    // MARK: - 写操作之后

    /// 某条还在不在库里。删除写完回读校正用（这套接口「回 ok」不算删掉了）。
    func contains(id: Int) -> Bool {
        for day in days where items[day.id]?.contains(where: { $0.id == id }) == true {
            return true
        }
        return false
    }

    /// 本地剔除。删除请求发出去之后先按这个把界面改掉 —— 删没删掉由随后的
    /// 静默重拉校正（这张接口对不存在的 id 也回 `success`，「回了 ok」不算证据）。
    func forget(ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        var keptDays: [PhotosAPI.Day] = []
        for day in days {
            let kept = (items[day.id] ?? []).filter { !ids.contains($0.id) }
            if kept.isEmpty {
                items[day.id] = nil
            } else {
                items[day.id] = kept
                keptDays.append(day)
            }
        }
        days = keptDays
        viewSequence = viewSequence.filter { !ids.contains($0.id) }
        if let viewing = viewingID, ids.contains(viewing) { viewingID = nil }
        positionCache = nil
    }

    /// 静默重拉整库：**不进 `loading` 相位**，界面不闪。写操作完成后用它校正    /// 「以为删掉了、其实还在」的那种情况。
    func refreshQuietly(_ manager: SessionManager?) async {
        guard let manager else { return }
        var all: [PhotosAPI.Item] = []
        var offset = 0
        do {
            while true {
                let page = try await PhotosAPI.itemsPage(
                    offset: offset, limit: Self.pageSize, manager: manager)
                all.append(contentsOf: page)
                offset += page.count
                if page.count < Self.pageSize { break }
            }
        } catch {
            NSLog("[photos] 静默重拉失败：%@", Self.describe(error))
            return
        }
        group(all)
        if case .loading = phase { phase = .ready }
        NSLog("[photos] 静默重拉：%d 条，%d 天", all.count, days.count)
    }

    // MARK: - 缩略图

    /// 缩略图字节。命中缓存直接回；失败记下来，别每帧重试。
    ///
    /// 刚上传的那几张服务端还没有图，命中本机预览就直接回 —— 不走网络，
    /// 那个 404 是**必然**的，问一次白等一次。
    func thumbnail(for item: PhotosAPI.Item, manager: SessionManager?) async -> Data? {
        if let cached = thumbs[item.id] { return cached }
        if let preview = localPreviews[item.filename] { return preview }
        if thumbFailures.contains(item.id) { return nil }
        if loadingThumbs.contains(item.id) { return nil }
        guard let manager else { return nil }

        loadingThumbs.insert(item.id)
        defer { loadingThumbs.remove(item.id) }
        do {
            let data = try await PhotosAPI.thumbnail(item, size: .m, manager: manager)
            store(data, for: item.id)
            return data
        } catch {
            thumbFailures.insert(item.id)
            return nil
        }
    }

    /// 登记一批刚上传的本机小图（`PhotoUpload.previews` 产出的）。
    ///
    /// 键是文件名 —— 条目里只有文件名，没有完整路径。同名不同月的两张会互相顶掉，
    /// 顶掉的后果只是有一张贴了另一张的预览图，服务端图一到就被换掉。
    func adoptPreviews(_ previews: [String: Data]) {
        guard !previews.isEmpty else { return }
        for (name, data) in previews {
            localPreviews[name] = data
            if !previewOrder.contains(name) { previewOrder.append(name) }
            // 这些名字上一轮的失败记录不再成立：文件是刚落地的新条目。
            if let item = itemNamed(name) { thumbFailures.remove(item.id) }
        }
        let overflow = previewOrder.count - Self.previewLimit
        if overflow > 0 {
            for stale in previewOrder.prefix(overflow) { localPreviews[stale] = nil }
            previewOrder.removeFirst(overflow)
        }
        NSLog("[photos] 本机预览 %d 张待替换", localPreviews.count)
    }

    /// 还有本机预览没找到条目 —— 说明这一批没落在最新一页里（补传的老照片按拍摄
    /// 时间排到时间轴中段）。这种情况才值得跑一次静默全量，其余时候不必翻完全库。
    var hasOrphanPreviews: Bool {
        guard !localPreviews.isEmpty else { return false }
        for name in localPreviews.keys where itemNamed(name) == nil { return true }
        return false
    }

    /// 把本机预览换成服务端缩略图。上传收尾后隔一阵回头看一次 —— 缩略图是落地之后
    /// 才异步生成的，生成完之前问也是白问。取到一张摘一张，代数加一让网格重取。
    func sweepPendingThumbs(_ manager: SessionManager?) async {
        guard let manager, !localPreviews.isEmpty else { return }
        var replaced = 0
        for name in previewOrder where localPreviews[name] != nil {
            guard let item = itemNamed(name) else { continue }
            do {
                let data = try await PhotosAPI.thumbnail(item, size: .m, manager: manager)
                store(data, for: item.id)
                localPreviews[name] = nil
                replaced += 1
            } catch {
                thumbFailures.insert(item.id)
            }
        }
        previewOrder.removeAll { localPreviews[$0] == nil }
        if replaced > 0 {
            thumbRevision += 1
            NSLog("[photos] %d 张换成了服务端缩略图，剩 %d 张本机预览", replaced, localPreviews.count)
        }
    }

    /// 查看器的大图：同一条 `Thumbnail` 接口，尺寸换 `xl`（1280 长边）。
    /// 失败**不记名**：翻回来再看一次是合理的重试，与网格里那张不同。
    func fullImage(for item: PhotosAPI.Item, manager: SessionManager?) async -> Data? {
        if let cached = fulls[item.id] { return cached }
        guard let manager, !loadingFulls.contains(item.id) else { return nil }

        loadingFulls.insert(item.id)
        defer { loadingFulls.remove(item.id) }
        do {
            let data = try await PhotosAPI.thumbnail(item, size: .xl, manager: manager)
            fulls[item.id] = data
            if !fullOrder.contains(item.id) { fullOrder.append(item.id) }
            if fullOrder.count > Self.fullLimit {
                for id in fullOrder.prefix(fullOrder.count - Self.fullLimit) {
                    fulls[id] = nil
                }
                fullOrder.removeFirst(fullOrder.count - Self.fullLimit)
            }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - 查看器的前后

    /// 相对 `item` 挪 `step`（−1 / +1）。序列已在 `openViewer` 时定好，纯序列运算 ——
    /// 走到头回 `nil`，查看器据此把方向键禁掉。
    func neighbor(of item: PhotosAPI.Item, step: Int) -> PhotosAPI.Item? {
        guard let index = viewSequence.firstIndex(where: { $0.id == item.id }) else {
            return nil
        }
        let target = index + step
        return viewSequence.indices.contains(target) ? viewSequence[target] : nil
    }

    /// 查看器顶栏的「当天第几张」：从 1 起，第二个数是当天的张数。
    ///
    /// 按**当前序列**里同一天的那一组算（时间轴上就是全库当天的张数；人物 / 相册
    /// 里是这个人 / 这个相册当天的张数）—— 与分组头那个「N 张」对得上，跨天重置。
    func position(of item: PhotosAPI.Item) -> (index: Int, count: Int)? {
        if let cached = positionCache, cached.id == item.id {
            return (cached.index, cached.count)
        }
        let calendar = PhotoDate.utcCalendar
        let parts = calendar.dateComponents([.year, .month, .day], from: item.time)
        guard let y = parts.year, let m = parts.month, let d = parts.day else { return nil }
        var index = 0
        var count = 0
        for other in viewSequence {
            let c = calendar.dateComponents([.year, .month, .day], from: other.time)
            guard c.year == y, c.month == m, c.day == d else { continue }
            count += 1
            if other.id == item.id { index = count }
        }
        guard index > 0 else { return nil }
        positionCache = (item.id, index, count)
        return (index, count)
    }

    // MARK: - 目录与封面小图

    /// 条目所在目录（照片库内相对路径，形如 `/2026/10`）。查过一次就记住 ——
    /// 同一目录下几百张共用一次请求。
    func folderPath(of item: PhotosAPI.Item, manager: SessionManager?) async -> String? {
        if let cached = folderNames[item.folderID] { return cached }
        if folderMisses.contains(item.folderID) { return nil }
        guard let manager else { return nil }
        if let name = await PhotosAPI.folderName(folderID: item.folderID, manager: manager) {
            folderNames[item.folderID] = name
            return name
        }
        folderMisses.insert(item.folderID)
        return nil
    }

    /// 人物头像 / 相册封面这类「不是条目」的小图。
    ///
    /// - 人物：服务端只给 `cache_key`，前缀即 `unit_id`；
    /// - 相册：先拿相册的第一张条目，再走条目缩略图（`seed` 由调用方给）。
    func coverImage(key: String, unitID: Int, cacheKey: String,
                    manager: SessionManager?) async -> Data? {
        if let cached = auxThumbs[key] { return cached }
        guard let manager, unitID > 0, !cacheKey.isEmpty else { return nil }
        do {
            let data = try await PhotosAPI.thumbnail(unitID: unitID, cacheKey: cacheKey,
                                                     size: .sm, manager: manager)
            auxThumbs[key] = data
            return data
        } catch {
            return nil
        }
    }

    // MARK: - 辅助

    /// 按文件名找已载入的条目。本机预览只有文件名这个键（条目里不带完整路径）。
    private func itemNamed(_ name: String) -> PhotosAPI.Item? {
        for day in days {
            if let hit = items[day.id]?.first(where: { $0.filename == name }) { return hit }
        }
        return nil
    }

    /// 存缩略图并按上限淘汰最早的那批。
    private func store(_ data: Data, for id: Int) {
        thumbs[id] = data
        if !thumbOrder.contains(id) { thumbOrder.append(id) }
        if thumbOrder.count > Self.thumbLimit {
            let drop = thumbOrder.count - Self.thumbLimit
            for stale in thumbOrder.prefix(drop) { thumbs[stale] = nil }
            thumbOrder.removeFirst(drop)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription {
            return text
        }
        return error.localizedDescription
    }
}

/// 照片的时间口径。服务端的 `time` / `indexed_time` 按 **UTC** 格式化才是
/// 拍摄那一刻的墙上时间（12 条样本里 11 条与文件名 `IMG_20261018_201238`
/// 逐字对上，按 +08:00 格式化整体多 8 小时）。所有日期文案只从这里出。
enum PhotoDate {
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    /// `2026年10月19日 17:30`
    static func stamp(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d年%02d月%02d日 %02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 文件大小：`1.3 MB`。照片信息栏与列表共用。
    static func bytes(_ value: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(value))
    }
}
