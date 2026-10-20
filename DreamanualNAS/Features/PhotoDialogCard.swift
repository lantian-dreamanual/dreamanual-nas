import SwiftUI

/// 照片的七张写操作弹窗：新建相册 / 相册改名 / 删除照片 / 删除相册 / 选一个相册 /
/// 人物命名改名 / 人物归并。
///
/// 挂在根视图（`RootView` 的 `.dmModal`），遮罩盖住整个窗口 —— 与文件写操作弹窗
/// 同一挂法、同一层序。请求挂在 `AppState.photoDialog` 上，冒烟通路能在视图之外
/// 把它摆出来截图核对。
struct PhotoDialogCard: View {
    @Environment(AppState.self) private var state
    let dialog: AppState.PhotoDialog

    /// 名字输入框的字（新建 / 改名共用）。
    @State private var name: String
    @State private var problem: String?
    /// 归并弹窗：选中的目标人物与目标过滤词。
    @State private var mergeTarget: PhotosAPI.Person?
    @State private var mergeQuery = ""
    @FocusState private var isFocused: Bool

    init(dialog: AppState.PhotoDialog) {
        self.dialog = dialog
        switch dialog {
        case .newAlbum:
            _name = State(initialValue: "新建相册")
        case .renameAlbum(let album):
            _name = State(initialValue: album.name)
        case .renamePerson(let person):
            _name = State(initialValue: person.isNamed ? person.name : "")
        case .delete, .addToAlbum, .deleteAlbum, .mergePerson:
            _name = State(initialValue: "")
        }
    }

    var body: some View {
        switch dialog {
        case .newAlbum:
            nameDialog(title: "新建相册", confirm: "创建") { value in
                await state.createPhotoAlbum(value)
            }
        case .renameAlbum(let album):
            nameDialog(title: "相册改名", confirm: "重命名") { value in
                await state.renamePhotoAlbum(album.id, to: value)
            }
        case .renamePerson(let person):
            nameDialog(title: person.isNamed ? "改名" : "命名",
                       confirm: person.isNamed ? "重命名" : "命名",
                       note: "名字会显示在人物卡与详情页。") { value in
                await state.renamePerson(person, to: value)
            }
        case .delete(let items):
            deleteDialog(items)
        case .deleteAlbum(let album):
            deleteAlbumDialog(album)
        case .addToAlbum(let items):
            albumPicker(items)
        case .mergePerson(let person):
            personPicker(person)
        }
    }

    // MARK: - 名字那几张

    private func nameDialog(title: String, confirm: String,
                            note: String = "共享空间的相册对所有能看到这个空间的人可见。",
                            submit: @escaping (String) async -> Bool) -> some View {
        DmModalCard(title: title, onClose: { state.closePhotoDialog() }) {
            VStack(alignment: .leading, spacing: DmSpace.s6) {
                FormLabel("名称")
                TextField("", text: $name)
                    .focused($isFocused)
                    .formField(on: .panel)
                Text(problem ?? note)
                    .font(.system(size: DmText.t11))
                    .foregroundColor(problem == nil ? Color.dmInk3 : Color.dmDangerInk)
            }
        } foot: {
            Button("取消") { state.closePhotoDialog() }
                .buttonStyle(SecondaryButtonStyle())
            Button(confirm) {
                let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    if await submit(value) { state.closePhotoDialog() }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isBlocked)
        }
        .onAppear {
            validate(name)
            isFocused = true
        }
        .onChange(of: name) { validate(name) }
    }

    /// 有问题的名字不发请求：本地先拦（空名服务端也拦，但让按钮灰着更直接）。
    private var isBlocked: Bool {
        problem != nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func validate(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            problem = "名字不能为空。"
        } else if trimmed.contains("/") {
            problem = "名字里不能有斜杠。"
        } else {
            problem = nil
        }
    }

    // MARK: - 删除

    private func deleteDialog(_ items: [PhotosAPI.Item]) -> some View {
        DmModalCard(title: Self.deleteTitle(items),
                    onClose: { state.closePhotoDialog() }) {
            DmDangerNote(text: "照片会从 NAS 的照片库里删除，不能撤销。")
            DmPickList {
                ForEach(items.prefix(6)) { item in
                    DmPickRow(icon: item.isVideo ? "film" : "image",
                              title: item.filename,
                              note: PhotoDate.bytes(item.filesize))
                }
                if items.count > 6 {
                    DmPickRow(icon: "ellipsis", title: "还有 \(items.count - 6) 张",
                              note: "")
                }
            }
        } foot: {
            Button("取消") { state.closePhotoDialog() }
                .buttonStyle(SecondaryButtonStyle())
            Button("删除") {
                state.closePhotoDialog()
                Task { await state.deletePhotos(items) }
            }
            .buttonStyle(DangerButtonStyle())
        }
    }

    static func deleteTitle(_ items: [PhotosAPI.Item]) -> String {
        guard items.count != 1 else { return "删除“\(items[0].filename)”？" }
        return "删除 \(items.count) 张照片？"
    }

    /// 删相册。**只删容器**，照片留在照片库里 —— 文案要把这条说清，
    /// 否则「删相册」听起来像连图一起没了。
    private func deleteAlbumDialog(_ album: PhotosAPI.Album) -> some View {
        DmModalCard(title: "删除相册“\(album.name)”？",
                    onClose: { state.closePhotoDialog() }) {
            DmDangerNote(text: "相册会从共享空间里删掉，不能撤销。")
            Text("里面的 \(album.itemCount) 张照片还在照片库里，只是不再归在这个相册下。")
                .font(.system(size: DmText.t12))
                .foregroundColor(Color.dmInk2)
                .fixedSize(horizontal: false, vertical: true)
        } foot: {
            Button("取消") { state.closePhotoDialog() }
                .buttonStyle(SecondaryButtonStyle())
            Button("删除相册") {
                state.closePhotoDialog()
                Task { await state.deletePhotoAlbum(album) }
            }
            .buttonStyle(DangerButtonStyle())
        }
    }

    // MARK: - 选一个相册

    private func albumPicker(_ items: [PhotosAPI.Item]) -> some View {
        DmModalCard(title: "添加到相册", onClose: { state.closePhotoDialog() }) {
            HStack(spacing: DmSpace.s8) {
                Text("\(items.count) 张")
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk2)
                Text("放进去之后照片仍在原来的位置，相册只是多了一层归类。")
                    .font(.system(size: DmText.t11))
                    .foregroundColor(Color.dmInk3)
            }
            if state.photoShelf.albums.isEmpty {
                Text("共享空间里还没有相册。")
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk3)
            } else {
                DmPickList {
                    ForEach(state.photoShelf.albums) { album in
                        Button {
                            state.closePhotoDialog()
                            Task { await state.addPhotos(items, to: album.id) }
                        } label: {
                            HStack(spacing: DmSpace.s8) {
                                LucideIcon("images", size: DmIcon.i14)
                                    .foregroundColor(Color.dmInk3)
                                Text(album.name)
                                    .font(.system(size: DmText.t13))
                                    .foregroundColor(Color.dmInk)
                                    .lineLimit(1)
                                Spacer(minLength: DmSpace.s8)
                                Text("\(album.itemCount) 张")
                                    .font(.system(size: DmText.t11))
                                    .monospacedDigit()
                                    .foregroundColor(Color.dmInk3)
                            }
                            .padding(.horizontal, DmSpace.s10)
                            .padding(.vertical, DmSpace.s8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } foot: {
            Button("新建相册…") {
                state.closePhotoDialog()
                state.openPhotoDialog(.newAlbum)
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("取消") { state.closePhotoDialog() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    // MARK: - 归并到…

    /// 人物归并：先从已命名人物里挑目标（客户端过滤），选中后出危险提示与
    /// 归并钮 —— 两段式，不让「点哪行就立刻并掉」这种不可逆动作跑得太顺。
    private func personPicker(_ person: PhotosAPI.Person) -> some View {
        let candidates = state.photoShelf.people.filter {
            $0.isNamed && $0.id != person.id &&
            (mergeQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(mergeQuery))
        }
        return DmModalCard(title: "归并到…", onClose: { state.closePhotoDialog() }) {
            VStack(alignment: .leading, spacing: DmSpace.s6) {
                Text("把「\(person.displayName)」（\(person.itemCount) 张）的照片并到另一个人物名下。")
                    .font(.system(size: DmText.t12))
                    .foregroundColor(Color.dmInk2)
                DmSearchField(text: $mergeQuery, placeholder: "搜索人物")
                if state.photoShelf.people.filter({ $0.isNamed && $0.id != person.id }).isEmpty {
                    Text("还没有已命名的人物。先把某个人物命名，再把他当归并目标。")
                        .font(.system(size: DmText.t12))
                        .foregroundColor(Color.dmInk3)
                } else if candidates.isEmpty {
                    Text("没有匹配「\(mergeQuery)」的人物。")
                        .font(.system(size: DmText.t12))
                        .foregroundColor(Color.dmInk3)
                } else {
                    DmPickList {
                        ForEach(candidates) { candidate in
                            Button {
                                mergeTarget = mergeTarget?.id == candidate.id ? nil : candidate
                            } label: {
                                HStack(spacing: DmSpace.s8) {
                                    LucideIcon("user", size: DmIcon.i14)
                                        .foregroundColor(mergeTarget?.id == candidate.id
                                                         ? Color.dmAccent : Color.dmInk3)
                                    Text(candidate.name)
                                        .font(.system(size: DmText.t13))
                                        .foregroundColor(Color.dmInk)
                                        .lineLimit(1)
                                    Spacer(minLength: DmSpace.s8)
                                    Text("\(candidate.itemCount) 张")
                                        .font(.system(size: DmText.t11))
                                        .monospacedDigit()
                                        .foregroundColor(Color.dmInk3)
                                }
                                .padding(.horizontal, DmSpace.s10)
                                .padding(.vertical, DmSpace.s8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let target = mergeTarget {
                    DmDangerNote(text: "「\(person.displayName)」的全部照片会归到「\(target.name)」名下，人物会消失，不能撤销。")
                }
            }
        } foot: {
            Button("取消") { state.closePhotoDialog() }
                .buttonStyle(SecondaryButtonStyle())
            Button("归并") {
                guard let target = mergeTarget else { return }
                state.closePhotoDialog()
                Task { await state.mergePerson(person, into: target) }
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(mergeTarget == nil)
        }
        // 弹窗层复用同一视图身份，上一次挑的目标不能带进来。
        .onAppear { mergeTarget = nil; mergeQuery = "" }
    }
}
