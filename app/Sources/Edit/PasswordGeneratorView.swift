import SwiftUI
import Security

enum PasswordGenerator {
    static func make(length: Int = 20,
                     lowers: Bool = true, uppers: Bool = true,
                     digits: Bool = true, symbols: Bool = true) -> String {
        var pool = ""
        if lowers { pool += "abcdefghijkmnopqrstuvwxyz" }
        if uppers { pool += "ABCDEFGHJKLMNPQRSTUVWXYZ" }
        if digits { pool += "23456789" }
        if symbols { pool += "!@#$%^&*-_=+?" }
        if pool.isEmpty { pool = "abcdefghijkmnopqrstuvwxyz" }
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        let chars = Array(pool)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }
}

struct PasswordGeneratorView: View {
    @Binding var password: String
    @Environment(\.dismiss) private var dismiss
    @State private var length = 20.0
    @State private var lowers = true
    @State private var uppers = true
    @State private var digits = true
    @State private var symbols = true
    @State private var preview = PasswordGenerator.make()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview)
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
            LabeledContent("长度 \(Int(length))") {
                Slider(value: $length, in: 12...40, step: 1)
                    .onChange(of: length) { regenerate() }
            }
            HStack {
                Toggle("小写", isOn: $lowers).toggleStyle(.checkbox)
                Toggle("大写", isOn: $uppers).toggleStyle(.checkbox)
                Toggle("数字", isOn: $digits).toggleStyle(.checkbox)
                Toggle("符号", isOn: $symbols).toggleStyle(.checkbox)
            }
            .onChange(of: lowers) { regenerate() }
            .onChange(of: uppers) { regenerate() }
            .onChange(of: digits) { regenerate() }
            .onChange(of: symbols) { regenerate() }
            HStack {
                Button("重新生成") { regenerate() }
                Spacer()
                Button("使用") {
                    password = preview
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func regenerate() {
        preview = PasswordGenerator.make(length: Int(length),
                                         lowers: lowers, uppers: uppers,
                                         digits: digits, symbols: symbols)
    }
}
