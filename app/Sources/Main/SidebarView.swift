import SwiftUI
import CofferCore

struct SidebarView: View {
    @Binding var section: SidebarSection?
    @EnvironmentObject var unlock: UnlockService

    private var allTags: [String] {
        Array(Set((unlock.document?.entries ?? []).flatMap(\.tags))).sorted()
    }

    var body: some View {
        List(selection: $section) {
            Section {
                Label("全部", systemImage: "tray.full").tag(SidebarSection.all)
                Label("收藏", systemImage: "star").tag(SidebarSection.favorites)
            }
            Section("分组") {
                ForEach(unlock.document?.groups ?? []) { group in
                    Label(group.name, systemImage: group.symbolName)
                        .tag(SidebarSection.group(group.id))
                }
            }
            if !allTags.isEmpty {
                Section("标签") {
                    ForEach(allTags, id: \.self) { tag in
                        Label("#\(tag)", systemImage: "tag")
                            .tag(SidebarSection.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 170, ideal: 210)
    }
}
