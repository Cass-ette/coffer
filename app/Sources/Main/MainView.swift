import SwiftUI
import CofferCore

enum SidebarSection: Hashable {
    case all, favorites
    case group(UUID)
    case tag(String)
}

struct MainView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var unlock: UnlockService
    @State private var section: SidebarSection? = .all
    @State private var selection: Entry.ID?
    @State private var query = ""

    private var index: SearchIndex {
        SearchIndex(entries: unlock.document?.entries ?? [])
    }

    private var visibleEntries: [Entry] {
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
                    app.didLock()
                } label: {
                    Label("锁定", systemImage: "lock.fill")
                }
            }
        }
    }
}
