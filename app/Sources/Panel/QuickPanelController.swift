import AppKit
import SwiftUI
import CofferCore

@MainActor
final class QuickPanelController: ObservableObject {
    static let shared = QuickPanelController()
    private var panel: FloatingPanel?

    func toggle(app: AppState) {
        if let panel, panel.isVisible {
            hide()
            return
        }
        switch app.phase {
        case .unlocked:
            present(app: app)
        case .locked:
            Task { @MainActor in
                let result = await app.unlock.unlockWithBiometrics()
                if case .unlocked = result {
                    app.phase = .unlocked
                    present(app: app)
                }
            }
        case .firstRun, .corrupted:
            return
        }
    }

    private func present(app: AppState) {
        let p = panel ?? makePanel()
        panel = p
        p.contentView = NSHostingView(rootView:
            QuickPanelView(onClose: { [weak self] in self?.hide() })
                .environmentObject(app)
                .environmentObject(app.unlock)
                .environmentObject(ClipboardManager.shared))
        if let screen = NSScreen.main {
            let frame = NSRect(x: screen.visibleFrame.midX - 280,
                               y: screen.visibleFrame.midY - 210,
                               width: 560, height: 420)
            p.setFrame(frame, display: true)
        }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.nonactivatingPanel, .titled,
                                          .fullSizeContentView, .resizable],
                              backing: .buffered, defer: false)
        p.title = "Coffer"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = true
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        return p
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
