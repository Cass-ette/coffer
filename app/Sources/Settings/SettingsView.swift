import SwiftUI
import CofferCore

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var unlock: UnlockService
    @ObservedObject private var appSettings = AppSettings.shared
    @State private var autoLockSeconds = 300
    @State private var clipboardSeconds = 45
    @State private var registrationFailed = false
    @State private var saveError: String?
    @State private var showingChangePassword = false
    @State private var confirmRestore = false
    @State private var confirmReset = false
    @State private var apiKeyCheck: Task<Void, Never>?
    @State private var checkingAPIKey = false
    @State private var apiKeyCheckResult: String?
    @State private var apiKeyValid = false

    private struct Choice: Identifiable {
        let label: String
        let seconds: Int
        var id: Int { seconds }
    }

    private static let lockChoices = [
        Choice(label: "1 分钟", seconds: 60), Choice(label: "5 分钟", seconds: 300),
        Choice(label: "15 分钟", seconds: 900), Choice(label: "不自动", seconds: 0),
    ]
    private static let clipboardChoices = [
        Choice(label: "30 秒", seconds: 30), Choice(label: "45 秒", seconds: 45),
        Choice(label: "60 秒", seconds: 60), Choice(label: "不清空", seconds: 0),
    ]

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时启动", isOn: $appSettings.launchAtLogin)
                LabeledContent("全局快捷键") {
                    HotkeyRecorder(settings: appSettings,
                                   registrationFailed: $registrationFailed)
                }
                if !app.hotkeyRegistered || registrationFailed {
                    Label("快捷键无效或被其他应用（如 Raycast）占用，请换一个组合后重试",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            securitySection
            Section("钱包") {
                SecureField("TronGrid API key（选填）", text: $appSettings.trongridApiKey)
                Text(appSettings.trongridApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "未配置：余额和转账查询正在使用匿名额度，容易受限流影响。"
                     : "已填写：新发起的余额、报价和转账请求会自动使用此 key，无需重启。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("在 TronGrid 注册或登录 → API Keys → 创建 key → 粘贴到上方 → 点验证。key 自动保存，不要把它发到聊天里。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("打开 TronGrid 控制台", destination: URL(string: "https://www.trongrid.io/")!)
                    Spacer()
                    if checkingAPIKey { ProgressView().controlSize(.small) }
                    Button("验证 API key", action: verifyTronGridKey)
                        .disabled(checkingAPIKey || appSettings.trongridApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let apiKeyCheckResult {
                    Text(apiKeyCheckResult).font(.caption).foregroundStyle(apiKeyValid ? .green : .orange)
                }
                Picker("余额缓存", selection: $appSettings.balanceCacheSeconds) {
                    Text("1 分钟").tag(60)
                    Text("5 分钟").tag(300)
                    Text("15 分钟").tag(900)
                }
            }
            GasFreeSettingsSection()
            Section("数据") {
                Button("从备份恢复…") { confirmRestore = true }
                    .disabled(!unlock.isUnlocked)
                Button("重置保险库…", role: .destructive) { confirmReset = true }
                LabeledContent("保险库位置") {
                    Text(VaultFileStore.defaultDirectory().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .frame(width: 520, height: 560)
        .onAppear { reseedPickers() }
        .onChange(of: unlock.isUnlocked) { reseedPickers() }
        .onChange(of: appSettings.hotkey) { registrationFailed = !app.reRegisterHotkey() }
        .onChange(of: appSettings.trongridApiKey) {
            apiKeyCheck?.cancel(); checkingAPIKey = false; apiKeyCheckResult = nil; apiKeyValid = false
        }
        .onDisappear { apiKeyCheck?.cancel(); checkingAPIKey = false }
        .sheet(isPresented: $showingChangePassword) {
            ChangeMasterPasswordSheet()
                .environmentObject(app)
                .environmentObject(unlock)
        }
        .confirmationDialog("用 vault.bak1 覆盖当前保险库？生物解锁不受影响。",
                            isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复", role: .destructive) {
                if app.unlock.restoreFromLatestBackup() {
                    app.didLock()
                } else {
                    saveError = "恢复失败：备份不可用"
                }
            }
        }
        .confirmationDialog("删除所有数据并重新创建？此操作不可撤销。",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("删除并重置", role: .destructive) {
                resetVault()
            }
        }
    }

    private func verifyTronGridKey() {
        let key = appSettings.trongridApiKey
        checkingAPIKey = true; apiKeyCheckResult = nil; apiKeyValid = false
        apiKeyCheck = Task { @MainActor in
            do {
                try await TronGridClient(http: URLSessionHTTP(), apiKey: key).verifyAPIKey()
                try Task.checkCancellation()
                apiKeyValid = true
                apiKeyCheckResult = "验证通过：TronGrid 已接受带 key 的只读请求。服务商额度与限流规则仍适用。"
            } catch {
                guard !Task.isCancelled else { return }
                apiKeyCheckResult = error.localizedDescription
            }
            checkingAPIKey = false
        }
    }

    private var securitySection: some View {
        Section("安全") {
            Picker("闲置自动锁定", selection: $autoLockSeconds) {
                ForEach(Self.lockChoices) { Text($0.label).tag($0.seconds) }
            }
            Picker("剪贴板清空", selection: $clipboardSeconds) {
                ForEach(Self.clipboardChoices) { Text($0.label).tag($0.seconds) }
            }
            Button("更改主密码…") { showingChangePassword = true }
            if !unlock.isUnlocked {
                Text("解锁主窗口后可修改这些安全设置")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(.red)
            }
        }
        .disabled(!unlock.isUnlocked)
        .onChange(of: autoLockSeconds) { applySecuritySettings() }
        .onChange(of: clipboardSeconds) { applySecuritySettings() }
    }

    private func reseedPickers() {
        autoLockSeconds = unlock.document?.settings.autoLockSeconds ?? 300
        clipboardSeconds = unlock.document?.settings.clipboardClearSeconds ?? 45
    }

    private func applySecuritySettings() {
        guard unlock.isUnlocked, unlock.document != nil else { return }
        unlock.document?.settings.autoLockSeconds = autoLockSeconds
        unlock.document?.settings.clipboardClearSeconds = clipboardSeconds
        do {
            try unlock.persist()
            app.refreshLockPolicy()
            saveError = nil
        } catch {
            saveError = "保存失败：\(error.localizedDescription)（改动仍在内存中，未落盘）"
        }
    }

    private func resetVault() {
        unlock.discardVaultAndBackups()
        app.phase = .firstRun
    }
}

struct ChangeMasterPasswordSheet: View {
    @EnvironmentObject var unlock: UnlockService
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    // 不能叫 error：catch 块里的隐式 error 常量会遮蔽同名属性导致编译错误
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("更改主密码").font(.title3.bold())
            SecureField("当前主密码", text: $current)
            SecureField("新主密码（至少 8 位）", text: $new)
            SecureField("确认新主密码", text: $confirm)
            if !confirm.isEmpty && new != confirm {
                Text("两次输入不一致").font(.callout).foregroundStyle(.red)
            }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("更改") { change() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(current.isEmpty || new.count < 8 || new != confirm)
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func change() {
        guard case .unlocked = unlock.unlockWithMasterPassword(current) else {
            errorMessage = "当前主密码不对"
            return
        }
        do {
            try unlock.setMasterPassword(new)
            dismiss()
        } catch {
            errorMessage = "更改失败：\(error.localizedDescription)"
        }
    }
}
