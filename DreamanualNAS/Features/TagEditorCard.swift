import SwiftUI

/// 编辑歌曲信息弹窗（歌曲右键菜单「编辑歌曲信息」）。
///
/// 数据链：打开时先去 NAS 读现值（`TagEditor.load`，标签编辑内部接口），
/// 读到了才出表单；「保存」真写 ID3 到文件（`TagEditor.apply`，索引 0 秒
/// 跟上），落地后曲库行与队列里的拷贝原位替换。所有字段**全量回传** ——
/// 没验证过缺字段时服务端是保留还是清空，别赌。
struct TagEditorCard: View {
    @Environment(AppState.self) private var state

    /// 表单草稿。NAS 读到现值时灌初值（只灌一次，用户改到一半不回读覆盖）。
    @State private var draft = SongTagInfo.empty
    /// 数值三格留字符串（输入中允许半截），提交时统一解析。
    @State private var yearText = ""
    @State private var trackText = ""
    @State private var discText = ""
    @State private var commentText = ""
    /// 现值灌过初值没有。
    @State private var hydrated = false
    /// 本地先判出的问题（数值格填了非数字）。有值时确认钮灰着。
    @State private var problem: String?

    var body: some View {
        Group {
            if let editor = state.tagEditor {
                DmModalCard(title: "编辑歌曲信息", onClose: { state.closeTagEditor() }) {
                    content(editor)
                } foot: {
                    Button("取消") { state.closeTagEditor() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("保存") { save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(editor.info == nil || editor.isSaving || problem != nil)
                }
                .onAppear(perform: hydrate)
                .onChange(of: editor.info) { hydrate() }
            }
        }
    }

    // MARK: - 卡身

    @ViewBuilder
    private func content(_ editor: AppState.TagEditorState) -> some View {
        // 定位行：文件在 NAS 上的完整路径（尾部对齐——用户要认的是文件名）。
        HStack(spacing: DmSpace.s8) {
            Text("文件")
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk3)
            Text((editor.song.path as NSString).lastPathComponent)
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }

        if let error = editor.errorMessage {
            Text(error)
                .font(.system(size: DmText.t13))
                .foregroundColor(Color.dmDanger)
        } else if editor.info == nil {
            Text("正在读取标签…")
                .font(.system(size: DmText.t13))
                .foregroundColor(Color.dmInk3)
        } else {
            form(editor)
        }
    }

    private func form(_ editor: AppState.TagEditorState) -> some View {
        VStack(alignment: .leading, spacing: DmSpace.s10) {
            fieldRow("标题", text: binding(\.title))
            fieldRow("艺术家", text: binding(\.artist))
            fieldRow("专辑", text: binding(\.album))
            fieldRow("专辑艺术家", text: binding(\.albumArtist))
            HStack(alignment: .top, spacing: DmSpace.s12) {
                fieldRow("流派", text: binding(\.genre))
                fieldRow("作曲", text: binding(\.composer))
            }
            HStack(alignment: .top, spacing: DmSpace.s12) {
                numberRow("年份", text: $yearText)
                numberRow("音轨", text: $trackText)
                numberRow("碟号", text: $discText)
            }
            fieldRow("注释", text: $commentText)

            Text(problem ?? "保存会改写 NAS 上的文件。")
                .font(.system(size: DmText.t12))
                .foregroundColor(problem != nil ? Color.dmDanger : Color.dmInk3)
        }
    }

    private func fieldRow(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DmSpace.s6) {
            FormLabel(label)
            TextField("", text: text)
                .formField(on: .panel)
        }
    }

    /// 文本草稿的绑定捷径（draft 是一份结构体拷贝，按键路径读写）。
    private func binding(_ kp: WritableKeyPath<SongTagInfo, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: kp] }, set: { draft[keyPath: kp] = $0 })
    }

    private func numberRow(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DmSpace.s6) {
            FormLabel(label)
            TextField("不设置", text: text)
                .formField(on: .panel)
        }
    }

    // MARK: - 数据

    private func hydrate() {
        guard !hydrated, let info = state.tagEditor?.info else { return }
        draft = info
        yearText = info.year.map(String.init) ?? ""
        trackText = info.track.map(String.init) ?? ""
        discText = info.disc.map(String.init) ?? ""
        commentText = info.comment
        hydrated = true
    }

    /// 数值格：空 = 不设；填了就得是整数。
    private func parse(_ text: String) -> Int?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let n = Int(trimmed) else { return nil }
        return n
    }

    private func validate() {
        for (label, text) in [("年份", yearText), ("音轨", trackText), ("碟号", discText)] {
            if parse(text) == nil {
                problem = "\(label)要填数字，或留空。"
                return
            }
        }
        problem = nil
    }

    private func save() {
        validate()
        guard problem == nil else { return }
        var info = draft
        info.comment = commentText
        info.year = parse(yearText) ?? nil
        info.track = parse(trackText) ?? nil
        info.disc = parse(discText) ?? nil
        Task { await state.saveTagEditor(info) }
    }
}
