import Foundation

/// 区县 → 地级市 / 省的对照表。
///
/// **为什么在客户端补**：群晖照片的地点条目只有 `first_level`（龙游县 /
/// 浦东新区 / 兰溪市 —— 区、县、县级市、地级市混在一层）与 `second_level`
/// （乡镇街道），**没有市与省**，也没有任何 `additional` 能取到（2026-10-21
/// `photosprobe64` 实测，全回 120）。于是「搜衢州」命中不了龙游 —— 照片在
/// 龙游县小南海镇，而这两个词里都没有「衢州」。
///
/// 表由 `scripts/gen-divisions.mjs` 从民政部区划代码（npm `china-division`）
/// 生成，共 3300+ 条、140 KB，构建产物随包走，运行时不联网。
enum ChinaDivisions {
    /// 一级区划名 → [市, 省]。同名重名（如「城区」）按后写入的算，代价只是归错组。
    private static let table: [String: [String]] = load()

    static func city(of firstLevel: String) -> String? {
        table[firstLevel]?.first
    }

    static func province(of firstLevel: String) -> String? {
        guard let row = table[firstLevel], row.count > 1 else { return nil }
        return row[1]
    }

    /// 搜索用的全部可命中词：乡镇（`second_level`）、县区、市、省。
    /// 「衢州」在龙游的条目里出现的就是这里补出来的市名。
    static func searchWords(firstLevel: String, secondLevel: String) -> [String] {
        var words = [secondLevel, firstLevel]
        if let city = city(of: firstLevel) { words.append(city) }
        if let province = province(of: firstLevel) { words.append(province) }
        // 「衢州市」也要能被「衢州」命中：去掉行政后缀再收一份。
        for word in words {
            let bare = stripSuffix(word)
            if bare != word { words.append(bare) }
        }
        return words
    }

    /// 去掉行政区划后缀，「龙游县」→「龙游」、「衢州市」→「衢州」。
    /// 🔴 只剥末尾一个后缀，且「市辖区 / 省直辖」这类不是真名的不动。
    static func stripSuffix(_ name: String) -> String {
        for suffix in ["特别行政区", "自治区", "自治州", "自治县", "自治旗",
                       "新区", "林区", "街道", "社区", "省", "市", "县", "区", "旗", "镇", "乡"] {
            if name.hasSuffix(suffix), name.count > suffix.count + 1 {
                return String(name.dropLast(suffix.count))
            }
        }
        return name
    }

    private static func load() -> [String: [String]] {
        guard let url = Bundle.main.url(forResource: "ChinaDivisions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            NSLog("[photos] 区划表没读进来（ChinaDivisions.json 缺失？）地点只能按原名匹配")
            return [:]
        }
        return raw
    }
}
