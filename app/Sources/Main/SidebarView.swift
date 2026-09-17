import SwiftUI
import CofferCore

struct SidebarView: View {
    @Binding var section: SidebarSection?
    @Binding var dragConfirmation: DragConfirmation?
    @EnvironmentObject var unlock: UnlockService
    @State private var showingAddGroup = false
    @State private var newGroupName = ""
    @State private var newGroupIcon = "folder"

    private var allTags: [String] {
        Array(Set((unlock.document?.entries ?? []).flatMap(\.tags))).sorted()
    }

    var body: some View {
        List(selection: $section) {
            Section {
                Label("全部", systemImage: "tray.full").tag(SidebarSection.all)
                Label("收藏", systemImage: "star").tag(SidebarSection.favorites)
            }
            Section {
                ForEach(unlock.document?.groups ?? []) { group in
                    Label(group.name, systemImage: group.symbolName)
                        .tag(SidebarSection.group(group.id))
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items: items, to: group)
                        }
                        .contextMenu {
                            Button("删除", role: .destructive) {
                                deleteGroup(group)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("分组")
                    Spacer()
                    Button(action: { showingAddGroup = true }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
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
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .sheet(isPresented: $showingAddGroup) {
            AddGroupSheet(
                groupName: $newGroupName,
                groupIcon: $newGroupIcon,
                isPresented: $showingAddGroup,
                onSave: { addGroup() }
            )
        }
    }

    private func addGroup() {
        guard !newGroupName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard var doc = unlock.document else { return }

        let group = CofferCore.Group(name: newGroupName, symbolName: newGroupIcon)
        doc.groups.append(group)
        unlock.document = doc

        do {
            try unlock.persist()
            newGroupName = ""
            newGroupIcon = "folder"
        } catch {
            print("保存分组失败: \(error)")
        }
    }

    private func deleteGroup(_ group: CofferCore.Group) {
        guard var doc = unlock.document else { return }

        // 从所有条目中移除该分组ID
        for i in doc.entries.indices {
            doc.entries[i].groupIDs.removeAll { $0 == group.id }
        }

        // 删除分组
        doc.groups.removeAll { $0.id == group.id }
        unlock.document = doc

        do {
            try unlock.persist()
            // 如果当前选中的就是被删除的分组，切换到"全部"
            if case .group(let id) = section, id == group.id {
                section = .all
            }
        } catch {
            print("删除分组失败: \(error)")
        }
    }

    private func handleDrop(items: [String], to group: CofferCore.Group) -> Bool {
        guard let entryIDString = items.first,
              let entryID = UUID(uuidString: entryIDString),
              let entry = unlock.document?.entries.first(where: { $0.id == entryID }) else {
            return false
        }

        // 如果已在目标分组，不处理
        if entry.groupIDs.contains(group.id) {
            return false
        }

        // 当前选中的分组ID（作为源分组）
        let sourceGroupID: UUID? = if case .group(let id) = section { id } else { nil }

        dragConfirmation = DragConfirmation(
            entryID: entryID,
            sourceGroupID: sourceGroupID,
            targetGroupID: group.id,
            entryTitle: entry.title
        )
        return true
    }
}

struct AddGroupSheet: View {
    @Binding var groupName: String
    @Binding var groupIcon: String
    @Binding var isPresented: Bool
    let onSave: () -> Void

    private let commonIcons = [
        "folder", "network", "server.rack", "lock.shield",
        "graduationcap", "building.2", "house",
        "chevron.left.forwardslash.chevron.right",
        "key", "person", "briefcase", "globe"
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("新建分组")
                .font(.headline)

            TextField("分组名称", text: $groupName)
                .textFieldStyle(.roundedBorder)

            Text("选择图标")
                .font(.subheadline)
                .foregroundColor(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(commonIcons, id: \.self) { icon in
                    Button(action: { groupIcon = icon }) {
                        Image(systemName: icon)
                            .font(.title2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(height: 44)
                    .background(groupIcon == icon ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("创建") {
                    onSave()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
