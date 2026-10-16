import WidgetKit
import SwiftUI

// ============ NAS 状态小组件（WidgetKit 管线） ============
//
// 数据链路：优先读主 app 落的共享快照（WidgetBridge，直写 widget 沙箱容器），
// 30 分钟内直接用；过期先自己连一次 NAS（端点、账号与口令都随快照带）；
// 都不行就转离线态，「上次在线」取旧快照的 takenAt。
// 刷新节奏：请求 15 分钟一档；主 app 每次落盘都会捅一次时间线。

@main
struct NASStatusWidgetBundle: WidgetBundle {
    var body: some Widget {
        NASStatusWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let display: NASWidgetDisplay
    let family: NASStatusContent.Family
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        Self.entry(from: WidgetBridge.read(), date: Date(), family: family(context))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        Task { completion(await Self.resolve(date: Date(), family: family(context))) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        Task {
            let entry = await Self.resolve(date: Date(), family: family(context))
            completion(Timeline(entries: [entry],
                                policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    private func family(_ context: Context) -> NASStatusContent.Family {
        context.family == .systemMedium ? .medium : .small
    }

    static func entry(from data: WidgetSnapshotData?, date: Date,
                      family: NASStatusContent.Family) -> SnapshotEntry {
        let display: NASWidgetDisplay
        if let data {
            display = .make(from: data, date: date, family: family)
        } else {
            display = .offline(title: "连不上", lastOnline: nil)
        }
        return SnapshotEntry(date: date, display: display, family: family)
    }

    /// 快照新鲜直接用；过期先自拉一次（成则回写共享容器）；都不行转离线。
    static func resolve(date: Date, family: NASStatusContent.Family) async -> SnapshotEntry {
        let cached = WidgetBridge.read()
        if let cached, cached.isFresh(at: date) {
            return entry(from: cached, date: date, family: family)
        }
        if let cached, let snapshot = await WidgetFetcher.fetch(cached),
           var fresh = WidgetBridge.make(from: snapshot, endpointKey: cached.endpointKey,
                                         qcID: cached.qcID,
                                         directAddress: cached.directAddress,
                                         username: cached.username) {
            fresh.password = cached.password
            WidgetBridge.save(fresh)
            return entry(from: fresh, date: date, family: family)
        }
        // 离线态：标题与「上次在线」按档给（demo 第 10 稿：小卡「连不上」、
        // 中卡「连不上 NAS」，两档都只留「上次在线 MM-dd HH:mm」）。
        let title = family != .small ? "连不上 NAS" : "连不上"
        return SnapshotEntry(date: date,
                             display: .offline(title: title, lastOnline: cached?.takenAt),
                             family: family)
    }
}

/// 小组件自己连一次 NAS。端点与账号、口令都随快照带 —— 沙箱里读不了
/// 主 app 的 credential.json，口令在主 app 落盘时一并写进快照（0600 同档）。
enum WidgetFetcher {
    static func fetch(_ connection: WidgetSnapshotData) async -> SystemSnapshot? {
        guard let password = connection.password, !password.isEmpty else { return nil }
        guard let password = connection.password, !password.isEmpty else { return nil }
        let client: SynologyClient
        if let direct = DirectAddress.parse(connection.directAddress) {
            // 直连（局域网 / Tailscale）：自签证书放行，与主 app 同一规矩。
            client = SynologyClient(host: direct.host, port: direct.port, allowSelfSigned: true)
        } else if !connection.qcID.isEmpty {
            guard let endpoint = try? await QuickConnectResolver().resolve(id: connection.qcID) else {
                return nil
            }
            client = SynologyClient(host: endpoint.host, port: endpoint.port, allowSelfSigned: false)
        } else {
            return nil
        }
        let manager = SessionManager(client: client, account: connection.username,
                                     password: password)
        let snapshot = await SystemStatusAPI.fetch(manager)
        return snapshot.isEmpty ? nil : snapshot
    }
}

struct NASStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.dreamanual.nas.status", provider: Provider()) { entry in
            NASStatusContent(display: entry.display, family: entry.family)
                .containerBackground(for: .widget) { Color.dmPanel }
        }
        .configurationDisplayName("NAS 状态")
        .description(Text("NAS 助手是否在线：容量、CPU 与温度。"))
        .supportedFamilies([.systemSmall, .systemMedium])
        // 边距自己画（12px 内边距照 demo），别吃系统的默认 content margin。
        .contentMarginsDisabled()
    }
}
