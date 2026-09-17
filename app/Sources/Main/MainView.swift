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

struct MainView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var unlock: UnlockService
    @State private var section: SidebarSection? = .all
    @State private var selection: Entry.ID?
    @State private var query = ""
    @State private var editorTarget: EditorTarget?

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
            SidebarView(section: $section)
        } content: {
            EntryListView(entries: visibleEntries, selection: $selection)
        } detail: {
            if let entry = unlock.document?.entries.first(where: { $0.id == selection }) {
                EntryDetailView(entry: entry)
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
    }
}
