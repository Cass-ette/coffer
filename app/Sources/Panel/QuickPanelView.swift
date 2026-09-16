import SwiftUI
import AppKit
import CofferCore

struct QuickPanelView: View {
    let onClose: () -> Void
    @EnvironmentObject var unlock: UnlockService
    @EnvironmentObject var clipboard: ClipboardManager
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var targetIndex = 0
    @State private var now = Date()
    @FocusState private var focused: Bool
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var results: [Entry] {
        SearchIndex(entries: unlock.document?.entries ?? []).search(query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索标题 / 标签 / 地址…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { pair in
                        row(pair.element, index: pair.offset)
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            query = ""
            selectedIndex = 0
            targetIndex = 0
            focused = true
        }
        .onChange(of: query) {
            selectedIndex = 0
            targetIndex = 0
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, max(results.count - 1, 0))
            targetIndex = 0
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0)
            targetIndex = 0
            return .handled
        }
        .onKeyPress(.tab) {
            cycleTarget()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) {
                openSelectedURL()
            } else {
                copyPrimary()
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onReceive(timer) { now = $0 }
    }

    @ViewBuilder
    private func row(_ entry: Entry, index: Int) -> some View {
        let targets = CopyTargets.targets(for: entry)
        let isSel = index == selectedIndex
        HStack(spacing: 10) {
            Image(systemName: entry.type.symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                Text(entry.subtitle.isEmpty ? targets.first?.label ?? "" : entry.subtitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isSel, !targets.isEmpty {
                Text(iselTargetLabel(targets))
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quinary, in: Capsule())
            }
            if case .totp(let p) = entry.payload {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(currentTOTP(entry) ?? "—")
                        .font(.system(.callout, design: .monospaced))
                    Text("\(totpRemaining(p))s")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSel ? Color.accentColor.opacity(0.14) : .clear)
        .onTapGesture(count: 2) { selectedIndex = index; copyPrimary() }
    }

    private func iselTargetLabel(_ targets: [CopyTarget]) -> String {
        guard !targets.isEmpty else { return "" }
        let t = targets[min(targetIndex, targets.count - 1)]
        return "↵ \(t.label)"
    }

    private func currentTOTP(_ entry: Entry) -> String? {
        CopyTargets.targets(for: entry, at: now).first?.value
    }

    private func totpRemaining(_ p: TOTPPayload) -> Int {
        guard let secret = try? Base32.decode(p.secretBase32) else { return 0 }
        let cfg = TOTPConfig(secret: secret,
                             algorithm: TOTPAlgorithm(rawValue: p.algorithm) ?? .SHA1,
                             digits: p.digits, period: max(p.period, 1))
        return TOTPGenerator(config: cfg).remainingSeconds(at: now)
    }

    private func openSelectedURL() {
        guard results.indices.contains(selectedIndex),
              let url = CopyTargets.firstURL(of: results[selectedIndex]) else { return }
        NSWorkspace.shared.open(url)
        onClose()
    }

    private func cycleTarget() {
        guard results.indices.contains(selectedIndex) else { return }
        let count = CopyTargets.targets(for: results[selectedIndex]).count
        guard count > 0 else { return }
        targetIndex = (targetIndex + 1) % count
    }

    private func copyPrimary() {
        guard results.indices.contains(selectedIndex) else { onClose(); return }
        let entry = results[selectedIndex]
        let targets = CopyTargets.targets(for: entry)
        if targets.isEmpty { onClose(); return }
        let target = targets[min(targetIndex, targets.count - 1)]
        let seconds = unlock.document?.settings.clipboardClearSeconds ?? 45
        ClipboardManager.shared.copy(target.value, autoClearSeconds: seconds)
        onClose()
    }
}
