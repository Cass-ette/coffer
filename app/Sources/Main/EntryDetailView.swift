import SwiftUI
import CofferCore

struct EntryDetailView: View {
    let entry: Entry
    let currentGroupID: UUID?
    @Binding var deleteConfirmation: DeleteConfirmation?
    @EnvironmentObject var app: AppState
    @EnvironmentObject var unlock: UnlockService
    @State private var revealed = Set<String>()
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                totpBlock
                fieldCard
                if !entry.permissionNote.isEmpty {
                    section("我的权限") {
                        Text(entry.permissionNote).textSelection(.enabled)
                    }
                }
                if !entry.tags.isEmpty {
                    section("标签") {
                        HStack {
                            ForEach(entry.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.quinary, in: Capsule())
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: toggleFavorite) {
                    Label("收藏", systemImage: entry.isFavorite ? "star.fill" : "star")
                }
                Button("编辑") { editing = true }
                Button(role: .destructive) {
                    deleteConfirmation = DeleteConfirmation(
                        entry: entry,
                        currentGroupID: currentGroupID
                    )
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $editing) {
            EntryEditorView(editing: entry)
                .environmentObject(app)
                .environmentObject(unlock)
        }
    }

    private func toggleFavorite() {
        guard var doc = unlock.document else { return }
        guard let index = doc.entries.firstIndex(where: { $0.id == entry.id }) else { return }

        doc.entries[index].isFavorite.toggle()
        unlock.document = doc

        do {
            try unlock.persist()
        } catch {
            print("切换收藏失败: \(error)")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.type.symbol)
                .font(.title2).foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.title2.bold())
                Text(entry.type.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var totpBlock: some View {
        if case .totp(let payload) = entry.payload {
            section("当前验证码") {
                TOTPCodeView(payload: payload,
                             autoClearSeconds: unlock.document?.settings.clipboardClearSeconds ?? 45)
            }
        }
    }

    @ViewBuilder
    private var fieldCard: some View {
        let rows = detailRows
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { pair in
                    let row = pair.element
                    DetailRowView(row: row,
                                  revealed: revealed.contains(row.id)) {
                        if revealed.contains(row.id) { revealed.remove(row.id) }
                        else { revealed.insert(row.id) }
                    } onCopy: {
                        ClipboardManager.shared.copy(
                            row.value,
                            autoClearSeconds: unlock.document?.settings.clipboardClearSeconds ?? 45)
                    }
                    if pair.offset < rows.count - 1 { Divider() }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    struct DetailRow: Identifiable {
        let id: String
        let label: String
        let value: String
        let isSecret: Bool
        let isMonospaced: Bool
        let link: URL?
    }

    private var detailRows: [DetailRow] {
        var rows: [DetailRow] = []
        var n = 0
        func add(_ label: String, _ value: String, secret: Bool = false,
                 mono: Bool = false, link: URL? = nil) {
            guard !value.isEmpty else { return }
            rows.append(DetailRow(id: "\(n)-\(label)", label: label, value: value,
                                  isSecret: secret, isMonospaced: mono, link: link))
            n += 1
        }
        switch entry.payload {
        case .login(let p):
            add("用户名", p.username)
            add("密码", p.password, secret: true)
            p.urls.forEach { add("地址", $0, link: URL(string: $0)) }
        case .access(let p):
            p.addresses.forEach { add("地址", $0, link: URL(string: $0)) }
            add("登录方式", p.loginMethod)
            add("网络", p.networkLocation)
            add("角色", p.roleNote)
        case .apiKey(let p):
            add("服务商", p.provider)
            add("密钥", p.secret, secret: true, mono: true)
            add("环境变量", p.envPrefix, mono: true)
        case .sshKey(let p):
            add("主机", p.host)
            add("用户", p.user)
            add("私钥", p.privateKey, secret: true, mono: true)
        case .database(let p):
            add("主机", p.host)
            add("端口", p.port)
            add("数据库名", p.databaseName)
            add("用户名", p.username)
            add("密码", p.password, secret: true)
            add("类型", p.dbType)
            add("网络", p.networkLocation)
        case .totp(let p):
            add("周期", "\(p.period)s")
        case .secureNote(let p):
            add("内容", p.body, secret: true)
            p.attachments.forEach { add("附件", $0.fileName) }
        }
        entry.customFields.forEach { add($0.name, $0.value, secret: $0.isSensitive) }
        return rows
    }

    @ViewBuilder
    private func section(_ title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

struct DetailRowView: View {
    let row: EntryDetailView.DetailRow
    let revealed: Bool
    let onToggleReveal: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label).font(.caption).foregroundStyle(.secondary)
                if row.isSecret && !revealed {
                    Text(String(repeating: "•", count: 12))
                        .font(.system(.body, design: .monospaced))
                        .redacted(reason: .placeholder)
                } else {
                    Text(row.value)
                        .font(row.isMonospaced ? .system(.body, design: .monospaced) : .body)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if row.isSecret {
                Button(action: onToggleReveal) {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            if let link = row.link {
                Link(destination: link) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
