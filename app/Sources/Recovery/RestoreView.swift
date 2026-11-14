import SwiftUI
import CofferCore

@MainActor
struct RestoreView: View {
    let hasBackup: Bool
    @EnvironmentObject var app: AppState
    @State private var showingDiscardConfirmation = false
    @State private var showingBackupHelp = false
    @State private var showingRestoreConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("无法打开保险库")
                .font(.title.bold())

            Text("当前保险库文件无法读取。请先尝试恢复本机最近一次自动备份；不要选择重置，除非你确认要放弃现有数据。")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .foregroundStyle(.secondary)

            if hasBackup {
                Button("从本机自动备份恢复…") {
                    showingRestoreConfirmation = true
                }
                .buttonStyle(.borderedProminent)
            }

            Button("查看备份与恢复步骤") { showingBackupHelp = true }

            Text("保险库位置：\(VaultFileStore.defaultDirectory().path)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button("放弃保险库并重新创建…", role: .destructive) {
                showingDiscardConfirmation = true
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showingBackupHelp) { BackupHelpSheet() }
        .confirmationDialog("从本机自动备份恢复？", isPresented: $showingRestoreConfirmation,
                            titleVisibility: .visible) {
            Button("恢复备份") { restoreFromBackup() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将最近一份可读取的自动备份设为当前保险库，当前文件会保留在备份轮换中。备份之后新增的钱包和条目不会合并进来。")
        }
        .confirmationDialog("放弃保险库并重新创建？", isPresented: $showingDiscardConfirmation,
                            titleVisibility: .visible) {
            Button("放弃并重置", role: .destructive) {
                discardVault()
            }
        } message: {
            Text("会删除当前 vault.vault、本机三份自动备份和钥匙串解锁密钥。仅当已有独立且确认可用的备份时再继续。")
        }
        .alert("恢复失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "请退出 Coffer 并保留所有备份文件。")
        }
    }

    private func restoreFromBackup() {
        guard app.unlock.restoreFromLatestBackup() else {
            errorMessage = "本机自动备份恢复失败。请退出 Coffer，保留所有文件，不要重置保险库。"
            return
        }
        app.didLock()
    }

    private func discardVault() {
        app.unlock.discardVaultAndBackups()
        app.phase = .firstRun
    }
}

struct BackupHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WalletSheetLayout {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("备份与恢复").font(.title2.bold())
                    Spacer()
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Text("恢复会把保险库回到备份时的状态，不会合并新旧条目。旧备份中可能没有后来添加的钱包，它们仍保存在恢复前的救援副本中。")
                Text("本机自动备份").font(.headline)
                Text("每次保存会轮换保留三份加密备份。在设置中选择“从本机自动备份恢复”，确认后使用最近一份可读取的备份，随后重新解锁并核对内容。自动备份与原文件同在本机，不能代替外部备份。")
                Text("外部冷备份：按顺序恢复").font(.headline)
                step(1, "完全退出 Coffer（Command + Q）。在 Finder 按 Command + Shift + G 打开下方保险库目录。")
                Text(VaultFileStore.defaultDirectory().path)
                    .font(.caption.monospaced()).textSelection(.enabled)
                step(2, "把整个保险库文件夹复制到另一安全位置作为“恢复前救援副本”，确认 vault.vault 及已有备份均已复制。")
                step(3, "保留冷备份原件，将它的副本命名为 vault.vault，再替换保险库目录中的同名文件。这一步才是在恢复。保留已有的 vault.bak1–3。")
                step(4, "打开 Coffer，用该备份对应的主密码解锁，核对条目、钱包和备份时间。若只是在做恢复演练，核对后退出，再放回救援副本中的 vault.vault，并确认最新数据回来。")
                Text("恢复期间不要重置保险库，也不要在旧快照上新增或修改数据。遇到异常先退出，并保留所有副本。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number). ").fontWeight(.semibold)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
