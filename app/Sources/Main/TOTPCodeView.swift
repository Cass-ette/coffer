import SwiftUI
import CofferCore

struct TOTPCodeView: View {
    let payload: TOTPPayload
    let autoClearSeconds: Int
    @State private var now = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var generator: TOTPGenerator? {
        guard let secret = try? Base32.decode(payload.secretBase32) else { return nil }
        let cfg = TOTPConfig(secret: secret,
                             algorithm: TOTPAlgorithm(rawValue: payload.algorithm) ?? .SHA1,
                             digits: payload.digits,
                             period: max(payload.period, 1))
        return TOTPGenerator(config: cfg)
    }

    var body: some View {
        HStack(spacing: 14) {
            if let gen = generator {
                Text(gen.code(at: now))
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                    .kerning(3)
                    .textSelection(.enabled)
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: fraction(gen))
                        .stroke(fraction(gen) < 0.25 ? .red : Color.accentColor,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: now)
                }
                .frame(width: 22, height: 22)
                Button {
                    ClipboardManager.shared.copy(gen.code(at: Date()),
                        autoClearSeconds: autoClearSeconds)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            } else {
                Text("种子无法解析").foregroundStyle(.red)
            }
        }
        .onReceive(timer) { _ in
            now = Date()
        }
    }

    private func fraction(_ gen: TOTPGenerator) -> Double {
        Double(gen.remainingSeconds(at: now)) / Double(gen.config.period)
    }
}
