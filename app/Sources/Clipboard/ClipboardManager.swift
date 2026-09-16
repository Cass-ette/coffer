import AppKit
import Combine

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var secondsLeft: Int?
    private var timer: Timer?
    private var copiedText: String?

    func copy(_ text: String, autoClearSeconds: Int = 45) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard autoClearSeconds > 0 else { return }
        copiedText = text
        secondsLeft = autoClearSeconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                self.secondsLeft = (self.secondsLeft ?? 1) - 1
                if (self.secondsLeft ?? 0) <= 0 {
                    let pasteboard = NSPasteboard.general
                    if let copied = self.copiedText,
                       pasteboard.string(forType: .string) == copied {
                        pasteboard.clearContents()
                    }
                    self.secondsLeft = nil
                    self.copiedText = nil
                    t.invalidate()
                }
            }
        }
    }

    func cancelAutoClear() {
        timer?.invalidate()
        timer = nil
        secondsLeft = nil
        copiedText = nil
    }
}
