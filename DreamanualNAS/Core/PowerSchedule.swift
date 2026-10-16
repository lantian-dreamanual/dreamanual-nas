import Foundation

// ============ 开关机计划（模块三下半） ============

/// 一条计划任务：星期 + 时刻 + 开关。
///
/// 服务端（`SYNO.Core.Hardware.PowerSchedule` v1 `load`）给的正好是这四个字段，
/// **没有 id、也没有名字** —— 身份只能由这四件拼出来，而两条完全一样的任务在服务端
/// 并不冲突（拼出来的键会撞），所以这份结构**不做 `Identifiable`**，界面按行下标取。
struct PowerTask: Equatable {
    /// 两组任务，对应服务端的 `poweroff_tasks` / `poweron_tasks` 两个数组。
    enum Kind: String, CaseIterable {
        case poweroff
        case poweron

        /// 界面上的两个字。
        var label: String {
            switch self {
            case .poweroff: return "关机"
            case .poweron: return "开机"
            }
        }

        /// 写回时的字段名。
        var payloadKey: String {
            switch self {
            case .poweroff: return "poweroff_tasks"
            case .poweron: return "poweron_tasks"
            }
        }
    }

    var kind: Kind
    var enabled: Bool
    var hour: Int
    var minute: Int
    /// 0 = 周日 … 6 = 周六。
    ///
    /// 🔴 **0 是周日**，不是 ISO 那一套的「0 = 周一」。判据是这台机器自己的排法：
    /// 工作日的开机排 `1,2,3,4,5`、周末排 `0,6` —— 只有「0 是周日」才说得通
    /// （`docs/接口结论.md` 第二节）。
    /// 🔴 **6 是上界**：`"0,1,2,3,4,5,6"` 服务端原样收下；给 `7` 时 `save` 照回
    /// `success`，那条任务的 `weekdays` 却回读成空串 —— **非法数字被静默剥掉**。
    /// 界面上绝不能产出 6 以外的数字。
    var weekdays: [Int]

    /// `23:45`，两段都补零（这一列要与相邻行对齐）。
    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    /// 星期那一列的字。命名形态 → 单日 → 连排区间 → 逐个列出。
    ///
    /// 这一列在界面上是定宽的一栏，所以长组合要压：`周一至周五` 是 5 个字，
    /// 逐个列出是 14 个字。真实计划里 3 天以上的组合基本都是连排（工作日、周末、
    /// 周一至周三），压这一档就够了。
    var weekdayText: String {
        guard !weekdays.isEmpty else { return "未设星期" }
        let set = Set(weekdays)
        if set.count == 7 { return "每天" }
        if set == [1, 2, 3, 4, 5] { return "工作日" }
        if set == [0, 6] { return "周末" }
        let ordered = Self.weekOrder.filter { set.contains($0) }
        if ordered.count == 1 { return Self.dayName(ordered[0]) }
        if ordered.count >= 3,
           let first = ordered.first, let last = ordered.last,
           Self.isRun(ordered) {
            return Self.dayName(first) + "至" + Self.dayName(last)
        }
        return ordered.map(Self.dayName).joined(separator: "、")
    }

    /// 一周的排法，从周一到周日（显示与连排判定都按这个顺序，不是数字序）。
    static let weekOrder = [1, 2, 3, 4, 5, 6, 0]

    /// 数字直接就是表下标 —— 0 落在「周日」上，与 `weekdays` 的口径是同一件事实。
    static func dayName(_ index: Int) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names.indices.contains(index) ? names[index] : "周\(index)"
    }

    /// 这几个星期在这个排法上是不是连着的（`周一至周三` 的判据）。
    private static func isRun(_ ordered: [Int]) -> Bool {
        let slots = ordered.compactMap { weekOrder.firstIndex(of: $0) }
        guard slots.count == ordered.count else { return false }
        return zip(slots, slots.dropFirst()).allSatisfy { $1 == $0 + 1 }
    }
}

/// 整张计划表。
///
/// **一份列表**（不按种类分两栏）：界面上是一条 `星期 · 时刻 · 徽章 · 开关` 的行，
/// 徽章说明这一条是开机还是关机。顺序就是服务端原样（`poweroff_tasks` 段在前、
/// `poweron_tasks` 段在后），写回时按种类拆回两个数组 —— 服务端那份次序因此不会被
/// 客户端打乱。
struct PowerSchedule: Equatable {
    var tasks: [PowerTask]

    var isEmpty: Bool { tasks.isEmpty }

    /// `load` 的应答 → 这份结构。
    ///
    /// 两组各缺一组都算正常（只设了开机没设关机是常见形态），但**两个键都不在**时
    /// 判为坏应答 —— 那种应答多半不是这个接口给的，接着往下走会把空表当真相，
    /// 而写回空表就是把用户原有的计划抹掉。
    static func decode(_ raw: Any) throws -> PowerSchedule {
        guard let box = raw as? [String: Any] else {
            throw PowerScheduleError.badResponse(
                "应答不是字典：\(String(describing: raw).prefix(80))")
        }
        let keys = PowerTask.Kind.allCases.map(\.payloadKey)
        guard keys.contains(where: { box[$0] != nil }) else {
            throw PowerScheduleError.badResponse(
                "应答里没有 \(keys.joined(separator: " / "))：\(box.keys.sorted())")
        }
        var tasks: [PowerTask] = []
        for kind in PowerTask.Kind.allCases {
            for row in (box[kind.payloadKey] as? [[String: Any]]) ?? [] {
                tasks.append(PowerTask(
                    kind: kind,
                    // 这个接口的布尔与数字同样时松时紧（`enabled` 给过 true，
                    // 也可能给 "true"/1），容差与系统状态那批共用一个实现。
                    enabled: SystemStatusAPI.bool(row["enabled"]),
                    hour: int(row["hour"]) ?? 0,
                    minute: int(row["min"]) ?? 0,
                    weekdays: weekdays(row["weekdays"])
                ))
            }
        }
        return PowerSchedule(tasks: tasks)
    }

    /// `save` 的请求体。
    ///
    /// 🔴 **两个字段各是一个 JSON 数组串**（2026-10-17 实测）：`poweroff_tasks` 与
    /// `poweron_tasks` 都传 `[{...}]` 序列化后的字符串，幂等回写后回读逐字一致；
    /// `query.cgi` 里这个接口也标着 `requestFormat: JSON`。
    /// `weekdays` 必须是**逗号串**（`"2,3,4,5"`），不是数组。
    func payload() throws -> [String: String] {
        var out: [String: String] = [:]
        for kind in PowerTask.Kind.allCases {
            let rows: [[String: Any]] = tasks.filter { $0.kind == kind }.map { task in
                [
                    "enabled": task.enabled,
                    "hour": task.hour,
                    "min": task.minute,
                    "weekdays": task.weekdays.map(String.init).joined(separator: ","),
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: rows)
            guard let text = String(data: data, encoding: .utf8) else {
                throw PowerScheduleError.badResponse("计划序列化失败")
            }
            out[kind.payloadKey] = text
        }
        return out
    }

    /// 数字/字符串两种形态都收 —— 这一组字段在实测里给过 `0` 也给过 `"0"`。
    private static func int(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    /// `weekdays` → 数字数组：排序、去重、**只留 0–6**。
    ///
    /// 过滤上界是照服务端自己的行为对齐 —— 非法数字它本来就会剥掉，客户端再产出
    /// 就等于把垃圾写进计划（实测给 `7` 时 `save` 回 success 但那条任务的
    /// `weekdays` 变空串）。空串解出来是空数组，界面显示「未设星期」。
    private static func weekdays(_ value: Any?) -> [Int] {
        let text: String
        if let string = value as? String {
            text = string
        } else if let numbers = value as? [NSNumber] {
            text = numbers.map(\.stringValue).joined(separator: ",")
        } else {
            return []
        }
        let days = text.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (0...6).contains($0) }
        return Array(Set(days)).sorted()
    }
}

enum PowerScheduleError: LocalizedError {
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case let .badResponse(detail): return detail
        }
    }
}

/// 计划表的取数层。走**文件会话**（与系统状态那批同一条归口）。
enum PowerScheduleAPI {
    private static let api = "SYNO.Core.Hardware.PowerSchedule"
    /// 这个接口只有 v1（`query.cgi` 实测 `minVersion` = `maxVersion` = 1）。
    private static let version = 1

    static func load(_ manager: SessionManager) async throws -> PowerSchedule {
        let raw = try await manager.call(
            kind: .file, api: api, version: version, method: "load"
        )
        return try PowerSchedule.decode(raw)
    }

    /// 写回，然后**回读**，以回读的那一份为准。
    ///
    /// 🔴 `save` 回 `success` 只证明请求被收下。这个接口对非法的 `weekdays` 是
    /// 静默剥掉（回 success、那条任务变成空星期），与评分接口对不存在的 id 照样回
    /// `success` 同一族。判据是回读，不是回包 —— 界面也就不会显示一个服务端其实
    /// 没存下的状态。
    static func save(_ schedule: PowerSchedule, on manager: SessionManager) async throws -> PowerSchedule {
        let payload = try schedule.payload()
        _ = try await manager.call(
            kind: .file, api: api, version: version, method: "save", params: payload
        )
        return try await load(manager)
    }
}
