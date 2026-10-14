import Foundation

/// 文件列表里那 28×28 的缩略图缓存。
///
/// 与 `CoverStore` 同构（键改成一个就够了：文件路径本身就是唯一的），三件事一样：
///   ① **按路径做键** —— 同一行滚回来是零请求；
///   ② **负缓存** —— 音频 / 非媒体一律 404，那是常态不是异常，取不到也记下来，
///      否则每次滚回来都要重问一遍；
///   ③ **限流** —— 同时最多 4 个在飞，对面是家用 NAS 不是 CDN。
actor ThumbStore {
    static let shared = ThumbStore()

    private static let smoke = ProcessInfo.processInfo.environment["DM_SMOKE"] == "1"

    private static func smokeLog(_ text: String) {
        guard smoke else { return }
        NSLog("[thumb] %@", text)
    }

    private let maxConcurrent = 4

    private var cache: [String: Data?] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 取一个文件的缩略图。**取不到不报错**，回 `nil` 让界面退回图标 ——
    /// 只有图片与视频出图，其余类型 404 是接口的既定行为。
    func thumbnail(manager: SessionManager, path: String) async -> Data? {
        if let hit = cache[path] { return hit }
        if let task = inFlight[path] { return await task.value }

        let task = Task<Data?, Never> { [manager] in
            do {
                return try await FileStation.thumbnail(manager, path: path)
            } catch {
                Self.smokeLog("取图失败 \(path)：\(error.localizedDescription)")
                return nil
            }
        }
        inFlight[path] = task

        await acquire()
        let data = await task.value
        release()

        cache[path] = data
        inFlight[path] = nil
        return data
    }

    // MARK: - 限流

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        running += 1
    }

    private func release() {
        running -= 1
        guard let next = waiters.first else { return }
        waiters.removeFirst()
        next.resume()
    }
}
