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
