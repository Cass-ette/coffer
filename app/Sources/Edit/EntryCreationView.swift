import SwiftUI
import CofferCore

struct EntryCreationView: View {
    let preselectedGroupID: UUID?
    @EnvironmentObject private var unlock: UnlockService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedType: EntryType?
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private func matches(_ type: EntryType) -> Bool {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || (type.label + " " + type.purpose + " " + type.rawValue)
            .localizedCaseInsensitiveContains(text)
    }

    var body: some View {
        NavigationStack {
            if let selectedType {
                EntryEditorView(editing: nil, preselectedGroupID: preselectedGroupID, initialType: selectedType)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("想保存什么？").font(.title2.bold())
                    Text("选择一种条目，连接信息与秘密会放在对应的位置。")
                        .foregroundStyle(.secondary)
                    TextField("搜索类型，例如 SSH、密码、验证码…", text: $search)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(EntryCreationCategory.all) { category in
                                let types = category.types.filter(matches)
                                if !types.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(category.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                            ForEach(types, id: \.self) { type in
                                                Button { selectedType = type } label: {
                                                    HStack(alignment: .top, spacing: 12) {
                                                        Image(systemName: type.symbol).font(.title2).foregroundStyle(.tint)
                                                            .frame(width: 30, height: 32)
                                                        VStack(alignment: .leading, spacing: 5) {
                                                            Text(type.label).font(.headline)
                                                            Text(type.purpose).font(.caption).foregroundStyle(.secondary)
                                                                .fixedSize(horizontal: false, vertical: true)
                                                        }
                                                        Spacer(minLength: 0)
                                                    }
                                                    .frame(maxWidth: .infinity, minHeight: 55, alignment: .topLeading)
                                                    .padding(13)
                                                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                                                    .contentShape(RoundedRectangle(cornerRadius: 10))
                                                }.buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                            if !EntryCreationCategory.all.flatMap(\.types).contains(where: matches) {
                                ContentUnavailableView.search(text: search)
                            }
                        }
                    }
                }
                .padding(24)
                .navigationTitle("新建条目")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
                .onAppear { searchFocused = true }
            }
        }
        .frame(width: 650, height: 660)
        .onChange(of: unlock.isUnlocked) { _, unlocked in if !unlocked { dismiss() } }
    }
}
