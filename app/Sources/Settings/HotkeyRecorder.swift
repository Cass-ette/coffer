import SwiftUI
import AppKit

extension AppSettings.Hotkey {
    var displayText: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        return parts.joined() + KeyCodeNames.name(keyCode)
    }
}

enum KeyCodeNames {
    static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9", 29: "0",
        49: "Space", 36: "↵", 48: "Tab", 53: "Esc", 51: "⌫",
    ]
    static func name(_ keyCode: UInt32) -> String {
        names[keyCode] ?? "Key(\(keyCode))"
    }
}

struct HotkeyRecorder: View {
    @ObservedObject var settings: AppSettings
    @Binding var registrationFailed: Bool
    @State private var recording = false

    var body: some View {
        HStack(spacing: 10) {
            Text(settings.hotkey.displayText)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
            Button(recording ? "按下新组合…" : "修改") { recording = true }
                .disabled(recording)
            if recording {
                Button("取消") { recording = false }
            }
        }
        .background(KeyCatcher(recording: recording) { keyCode, modifiers in
            recording = false
            if keyCode == 53 { return }
            var mods: [AppSettings.HotkeyModifier] = []
            if modifiers.contains(.command) { mods.append(.command) }
            if modifiers.contains(.option) { mods.append(.option) }
            if modifiers.contains(.control) { mods.append(.control) }
            if modifiers.contains(.shift) { mods.append(.shift) }
            guard !mods.isEmpty else {
                registrationFailed = true
                return
            }
            settings.hotkey = AppSettings.Hotkey(keyCode: keyCode, modifiers: mods)
        })
    }
}

private struct KeyCatcher: NSViewRepresentable {
    let recording: Bool
    let onCapture: (UInt32, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onCapture = onCapture
        return v
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        if recording { nsView.beginCapture() } else { nsView.endCapture() }
    }

    static func dismantleNSView(_ nsView: CaptureView, coordinator: Coordinator) {
        nsView.endCapture()
    }

    final class CaptureView: NSView {
        var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Void)?
        private var monitor: Any?

        func beginCapture() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                self?.onCapture?(UInt32(event.keyCode), mods)
                self?.endCapture()
                return nil
            }
        }

        func endCapture() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
