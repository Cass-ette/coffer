import SwiftUI
import CofferCore
import UniformTypeIdentifiers

struct EntryEditorView: View {
    let editing: Entry?
    let preselectedGroupID: UUID?
    @EnvironmentObject var app: AppState
    @EnvironmentObject var unlock: UnlockService
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    @State private var type: EntryType = .login
    @State private var title = ""
    @State private var subtitle = ""
    @State private var groupID: UUID?
    @State private var tagsText = ""
    @State private var isFavorite = false
    @State private var permissionNote = ""
    @State private var customFields: [CustomField] = []

    @State private var loginUsername = ""
    @State private var loginPassword = ""
    @State private var loginURLs = ""
    @State private var accessAddresses = ""
    @State private var accessLoginMethod = "SSO"
    @State private var accessNetwork = "内网"
    @State private var accessRole = ""
    @State private var apiKeyProvider = ""
    @State private var apiKeySecret = ""
    @State private var apiKeyEnv = ""
    @State private var sshHost = ""
    @State private var sshUser = ""
    @State private var sshKey = ""
    @State private var dbHost = ""
    @State private var dbPort = ""
    @State private var dbName = ""
    @State private var dbUsername = ""
    @State private var dbPassword = ""
    @State private var dbType = "MySQL"
    @State private var dbNetwork = "内网"
    @State private var totpInput = ""
    @State private var noteBody = ""
    @State private var attachments: [Attachment] = []
    @State private var showFileImporter = false
    @State private var showGenerator = false
    @State private var now = Date()
    private let secondTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let loginMethods = ["SSO", "密码", "免登"]
    private let networks = ["内网", "公网"]
    private let dbTypes = ["MySQL", "PostgreSQL", "MongoDB", "Redis", "Oracle", "SQL Server", "SQLite"]
    private let maxAttachmentBytes = 2 * 1024 * 1024
    private let maxAttachmentCount = 5

    init(editing: Entry?, preselectedGroupID: UUID? = nil) {
        self.editing = editing
        self.preselectedGroupID = preselectedGroupID
        guard let e = editing else {
            // 新建条目时应用预选分组
            _groupID = State(initialValue: preselectedGroupID)
            return
        }
        _type = State(initialValue: e.type)
        _title = State(initialValue: e.title)
        _subtitle = State(initialValue: e.subtitle)
        _groupID = State(initialValue: e.groupIDs.first)
        _tagsText = State(initialValue: e.tags.joined(separator: ", "))
        _isFavorite = State(initialValue: e.isFavorite)
        _permissionNote = State(initialValue: e.permissionNote)
        _customFields = State(initialValue: e.customFields)
        switch e.payload {
        case .login(let p):
            _loginUsername = State(initialValue: p.username)
            _loginPassword = State(initialValue: p.password)
            _loginURLs = State(initialValue: p.urls.joined(separator: "\n"))
        case .access(let p):
            _accessAddresses = State(initialValue: p.addresses.joined(separator: "\n"))
            _accessLoginMethod = State(initialValue: p.loginMethod)
            _accessNetwork = State(initialValue: p.networkLocation)
            _accessRole = State(initialValue: p.roleNote)
        case .apiKey(let p):
            _apiKeyProvider = State(initialValue: p.provider)
            _apiKeySecret = State(initialValue: p.secret)
            _apiKeyEnv = State(initialValue: p.envPrefix)
        case .sshKey(let p):
            _sshHost = State(initialValue: p.host)
            _sshUser = State(initialValue: p.user)
            _sshKey = State(initialValue: p.privateKey)
        case .database(let p):
            _dbHost = State(initialValue: p.host)
            _dbPort = State(initialValue: p.port)
            _dbName = State(initialValue: p.databaseName)
            _dbUsername = State(initialValue: p.username)
            _dbPassword = State(initialValue: p.password)
            _dbType = State(initialValue: p.dbType)
            _dbNetwork = State(initialValue: p.networkLocation)
        case .totp(let p):
            _totpInput = State(initialValue: p.secretBase32)
        case .secureNote(let p):
            _noteBody = State(initialValue: p.body)
            _attachments = State(initialValue: p.attachments)
        }
    }

    var body: some View {
        Form {
            Section("基本信息") {
                if editing == nil {
                    Picker("类型", selection: $type) {
                        ForEach(EntryType.allCases, id: \.self) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                TextField("标题（必填）", text: $title)
                TextField("副标题（用户名/主机等，用于列表第二行）", text: $subtitle)
                Picker("分组", selection: $groupID) {
                    Text("无").tag(UUID?.none)
                    ForEach(unlock.document?.groups ?? []) { g in
                        Label(g.name, systemImage: g.symbolName).tag(UUID?.some(g.id))
                    }
                }
                TextField("标签（逗号分隔）", text: $tagsText)
                Toggle("收藏", isOn: $isFavorite)
                TextField("我的权限备注", text: $permissionNote, axis: .vertical)
                    .lineLimit(2...4)
            }

            typeSpecific

            Section("自定义字段") {
                ForEach(Array(customFields.enumerated()), id: \.offset) { index, field in
                    HStack {
                        TextField("名称", text: Binding(
                            get: { customFields[index].name },
                            set: { customFields[index].name = $0 }
                        ))
                        TextField("值", text: Binding(
                            get: { customFields[index].value },
                            set: { customFields[index].value = $0 }
                        ))
                        Toggle("敏感", isOn: Binding(
                            get: { customFields[index].isSensitive },
                            set: { customFields[index].isSensitive = $0 }
                        )).toggleStyle(.checkbox)
                        Button(role: .destructive) {
                            if index < customFields.count {
                                customFields.remove(at: index)
                            }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("添加字段") {
                    customFields.append(CustomField(name: "", value: "", isSensitive: false))
                }
            }

            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .onReceive(secondTimer) { now = $0 }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.isEmpty)
            }
        }
        .sheet(isPresented: $showGenerator) {
            PasswordGeneratorView(password: $loginPassword)
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                importAttachment(from: url)
            }
        }
    }

    @ViewBuilder
    private var typeSpecific: some View {
        switch type {
        case .login:
            Section("登录") {
                TextField("用户名", text: $loginUsername)
                HStack {
                    SecureField("密码", text: $loginPassword)
                    Button { showGenerator = true } label: { Image(systemName: "wand.and.stars") }
                        .buttonStyle(.borderless)
                }
                TextField("地址（一行一个，内网 IP 与域名可并存）", text: $loginURLs, axis: .vertical)
                    .lineLimit(1...4)
            }
        case .access:
            Section("访问权限") {
                TextField("系统地址（一行一个）", text: $accessAddresses, axis: .vertical)
                    .lineLimit(1...4)
                Picker("登录方式", selection: $accessLoginMethod) {
                    ForEach(loginMethods, id: \.self) { Text($0) }
                }
                Picker("网络位置", selection: $accessNetwork) {
                    ForEach(networks, id: \.self) { Text($0) }
                }
                TextField("我的角色/权限说明", text: $accessRole, axis: .vertical)
                    .lineLimit(2...4)
            }
        case .apiKey:
            Section("API 密钥") {
                TextField("服务商", text: $apiKeyProvider)
                TextField("密钥", text: $apiKeySecret)
                    .font(.system(.body, design: .monospaced))
                TextField("环境变量前缀（如 DEEPSEEK_API_KEY）", text: $apiKeyEnv)
            }
        case .sshKey:
            Section("SSH 密钥") {
                TextField("主机", text: $sshHost)
                TextField("用户", text: $sshUser)
                TextField("私钥", text: $sshKey, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3...8)
            }
        case .database:
            Section("数据库") {
                TextField("主机地址", text: $dbHost)
                TextField("端口", text: $dbPort)
                TextField("数据库名", text: $dbName)
                TextField("用户名", text: $dbUsername)
                SecureField("密码", text: $dbPassword)
                Picker("数据库类型", selection: $dbType) {
                    ForEach(dbTypes, id: \.self) { Text($0) }
                }
                Picker("网络位置", selection: $dbNetwork) {
                    ForEach(networks, id: \.self) { Text($0) }
                }
            }
        case .totp:
            Section("2FA 验证码") {
                TextField("种子（Base32）或完整 otpauth:// 链接", text: $totpInput, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...3)
                if let preview = totpPreview {
                    LabeledContent("当前验证码") {
                        Text(preview)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        case .secureNote:
            Section("安全笔记") {
                TextField("正文（纯文本）", text: $noteBody, axis: .vertical)
                    .lineLimit(6...16)
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, att in
                    HStack {
                        Image(systemName: "paperclip")
                        Text(att.fileName)
                        Spacer()
                        Button(role: .destructive) {
                            if index < attachments.count {
                                attachments.remove(at: index)
                            }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("添加附件（≤2MB，至多 5 张）") { showFileImporter = true }
                    .disabled(attachments.count >= maxAttachmentCount)
            }
        }
    }

    private var totpPreview: String? {
        guard let payload = buildTOTP() else { return nil }
        guard let secret = try? Base32.decode(payload.secretBase32) else { return nil }
        let cfg = TOTPConfig(secret: secret,
                             algorithm: TOTPAlgorithm(rawValue: payload.algorithm) ?? .SHA1,
                             digits: payload.digits, period: payload.period)
        return TOTPGenerator(config: cfg).code(at: now)
    }

    private func buildTOTP() -> TOTPPayload? {
        let input = totpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input.lowercased().hasPrefix("otpauth://") {
            guard let url = URL(string: input),
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let secret = comps.queryItems?.first(where: { $0.name == "secret" })?.value,
                  (try? Base32.decode(secret)) != nil else { return nil }
            let digits = Int(comps.queryItems?.first { $0.name == "digits" }?.value ?? "") ?? 6
            let period = Int(comps.queryItems?.first { $0.name == "period" }?.value ?? "") ?? 30
            let algo = (comps.queryItems?.first { $0.name == "algorithm" }?.value ?? "SHA1")
                .uppercased()
            return TOTPPayload(secretBase32: secret,
                               algorithm: TOTPAlgorithm(rawValue: algo)?.rawValue ?? "SHA1",
                               digits: digits, period: period)
        }
        guard (try? Base32.decode(input)) != nil else { return nil }
        return TOTPPayload(secretBase32: input.uppercased(),
                           algorithm: "SHA1", digits: 6, period: 30)
    }

    private func importAttachment(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        guard data.count <= maxAttachmentBytes else {
            error = "附件超过 2MB 上限"
            return
        }
        attachments.append(Attachment(
            fileName: url.lastPathComponent,
            mimeType: url.pathExtension.lowercased() == "png" ? "image/png" : "application/octet-stream",
            dataBase64: data.base64EncodedString()))
    }

    private func parseTags(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，# ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        let payload: EntryPayload
        switch type {
        case .login:
            payload = .login(LoginPayload(username: loginUsername,
                                          password: loginPassword,
                                          urls: lines(loginURLs)))
        case .access:
            payload = .access(AccessPayload(addresses: lines(accessAddresses),
                                            loginMethod: accessLoginMethod,
                                            networkLocation: accessNetwork,
                                            roleNote: accessRole))
        case .apiKey:
            payload = .apiKey(APIKeyPayload(provider: apiKeyProvider,
                                            secret: apiKeySecret, envPrefix: apiKeyEnv))
        case .sshKey:
            payload = .sshKey(SSHKeyPayload(host: sshHost, user: sshUser, privateKey: sshKey))
        case .database:
            payload = .database(DatabasePayload(host: dbHost, port: dbPort, databaseName: dbName,
                                                username: dbUsername, password: dbPassword,
                                                dbType: dbType, networkLocation: dbNetwork))
        case .totp:
            guard let p = buildTOTP() else {
                error = "种子无效：需合法 Base32 或 otpauth:// 链接"
                return
            }
            payload = .totp(p)
        case .secureNote:
            payload = .secureNote(SecureNotePayload(body: noteBody, attachments: attachments))
        }

        var entry = editing ?? Entry(
            id: UUID(), type: type, title: "", subtitle: "", groupIDs: [],
            tags: [], isFavorite: false, isHidden: false, permissionNote: "", customFields: [],
            createdAt: Date(), updatedAt: Date(), payload: payload)
        entry.type = type
        entry.title = title
        entry.subtitle = subtitle
        entry.groupIDs = groupID.map { [$0] } ?? []
        entry.tags = parseTags(tagsText)
        entry.isFavorite = isFavorite
        entry.permissionNote = permissionNote
        entry.customFields = customFields
        entry.payload = payload
        entry.updatedAt = Date()

        do {
            try app.upsert(entry)
            dismiss()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
    }
}
