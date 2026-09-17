import SwiftUI
import CofferCore

enum SidebarSection: Hashable {
    case all, favorites
    case group(UUID)
    case tag(String)
}

struct EditorTarget: Identifiable {
    let id = UUID()
    let entry: Entry?
    let preselectedGroupID: UUID?
}

enum DragAction {
    case move, copy
}

struct DragConfirmation: Identifiable {
    let id = UUID()
    let entryID: UUID
    let sourceGroupID: UUID?
    let targetGroupID: UUID
    let entryTitle: String
}

struct DeleteConfirmation: Identifiable {
    let id = UUID()
    let entry: Entry
    let currentGroupID: UUID?
}

struct MainView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var unlock: UnlockService
    @State private var section: SidebarSection? = .all
    @State private var selection: Entry.ID?
    @State private var query = ""
    @State private var editorTarget: EditorTarget?
    @State private var dragConfirmation: DragConfirmation?
    @State private var deleteConfirmation: DeleteConfirmation?
    @State private var fileMonitor: DispatchSourceFileSystemObject?

    private var visibleEntries: [Entry] {
        let index = SearchIndex(entries: unlock.document?.entries ?? [])
        guard let section else { return index.search(query: query) }
        switch section {
        case .all: return index.search(query: query)
        case .favorites: return index.search(query: query, favoritesOnly: true)
        case .group(let id): return index.search(query: query, groupID: id)
        case .tag(let t): return index.search(query: query, tag: t)
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(section: $section, dragConfirmation: $dragConfirmation)
        } content: {
            EntryListView(entries: visibleEntries, selection: $selection)
        } detail: {
            if let entry = unlock.document?.entries.first(where: { $0.id == selection }) {
                let currentGroupID: UUID? = if case .group(let id) = section { id } else { nil }
                EntryDetailView(entry: entry,
                               currentGroupID: currentGroupID,
                               deleteConfirmation: $deleteConfirmation)
                    .id(entry.id)
            } else {
                ContentUnavailableView("选择一个条目",
                                       systemImage: "lock.rectangle",
                                       description: Text("在左侧选择，或直接搜索"))
            }
        }
        .navigationTitle("Coffer")
        .searchable(text: $query, placement: .toolbar, prompt: "搜索标题 / 标签 / 地址")
        .toolbar {
            ToolbarItem {
                Button {
                    let groupID: UUID? = if case .group(let id) = section { id } else { nil }
                    editorTarget = EditorTarget(entry: nil, preselectedGroupID: groupID)
                } label: {
                    Label("新建条目", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button {
                    app.didLock()
                } label: {
                    Label("锁定", systemImage: "lock.fill")
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            EntryEditorView(editing: target.entry, preselectedGroupID: target.preselectedGroupID)
                .environmentObject(app)
                .environmentObject(unlock)
        }
        .alert("移动还是复制条目？", isPresented: Binding(
            get: { dragConfirmation != nil },
            set: { if !$0 { dragConfirmation = nil } }
        ), presenting: dragConfirmation) { confirmation in
            Button("取消", role: .cancel) { }
            Button("移动") {
                performDrag(confirmation: confirmation, action: .move)
            }
            Button("复制") {
                performDrag(confirmation: confirmation, action: .copy)
            }
        } message: { confirmation in
            Text("将「\(confirmation.entryTitle)」拖入新分组")
        }
        .alert("删除条目", isPresented: Binding(
            get: { deleteConfirmation != nil },
            set: { if !$0 { deleteConfirmation = nil } }
        ), presenting: deleteConfirmation) { confirmation in
            Button("取消", role: .cancel) { }
            if confirmation.currentGroupID != nil && !confirmation.entry.groupIDs.isEmpty {
                Button("从分组移除") {
                    performDelete(confirmation: confirmation, removeFromGroup: true)
                }
            }
            Button("彻底删除", role: .destructive) {
                performDelete(confirmation: confirmation, removeFromGroup: false)
            }
        } message: { confirmation in
            if confirmation.currentGroupID != nil && !confirmation.entry.groupIDs.isEmpty {
                Text("「\(confirmation.entry.title)」属于 \(confirmation.entry.groupIDs.count) 个分组")
            } else {
                Text("确定要删除「\(confirmation.entry.title)」吗？")
            }
        }
        .onAppear {
            startFileMonitoring()
        }
        .onDisappear {
            stopFileMonitoring()
        }
    }

    private func startFileMonitoring() {
        let vaultDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cc.cassette.coffer")
        let vaultPath = vaultDir.appendingPathComponent("vault.vault").path

        let fileDescriptor = open(vaultPath, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak app] in
            // 如果有编辑器打开，不刷新（避免打断用户）
            guard editorTarget == nil else { return }

            // 刷新数据
            do {
                try unlock.reload()
                print("✅ Vault 已自动刷新")
            } catch {
                print("❌ Vault 刷新失败: \(error)")
            }
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        fileMonitor = source
    }

    private func stopFileMonitoring() {
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    private func performDrag(confirmation: DragConfirmation, action: DragAction) {
        guard var doc = unlock.document else { return }
        guard let index = doc.entries.firstIndex(where: { $0.id == confirmation.entryID }) else { return }

        switch action {
        case .move:
            // 如果有源分组，从源分组移除；然后添加到目标分组
            if let sourceID = confirmation.sourceGroupID {
                doc.entries[index].groupIDs.removeAll { $0 == sourceID }
            }
            if !doc.entries[index].groupIDs.contains(confirmation.targetGroupID) {
                doc.entries[index].groupIDs.append(confirmation.targetGroupID)
            }
        case .copy:
            // 只添加到目标分组，不移除源分组
            if !doc.entries[index].groupIDs.contains(confirmation.targetGroupID) {
                doc.entries[index].groupIDs.append(confirmation.targetGroupID)
            }
        }

        unlock.document = doc
        do {
            try unlock.persist()
        } catch {
            print("保存失败: \(error)")
        }
    }

    private func performDelete(confirmation: DeleteConfirmation, removeFromGroup: Bool) {
        guard var doc = unlock.document else { return }

        if removeFromGroup, let groupID = confirmation.currentGroupID {
            // 从当前分组移除
            guard let index = doc.entries.firstIndex(where: { $0.id == confirmation.entry.id }) else { return }
            doc.entries[index].groupIDs.removeAll { $0 == groupID }
        } else {
            // 彻底删除
            doc.entries.removeAll { $0.id == confirmation.entry.id }
            if selection == confirmation.entry.id {
                selection = nil
            }
        }

        unlock.document = doc
        do {
            try unlock.persist()
        } catch {
            print("删除失败: \(error)")
        }
    }
}
