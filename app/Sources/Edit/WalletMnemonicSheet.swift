import SwiftUI

struct WalletMnemonicSheet: View {
    let words: [String]
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var checking = false
    @State private var choices: [Int] = []
    @State private var selected = Set<Int>()
    @State private var errorMessage: String?
    private let columns = Array(repeating: GridItem(.flexible()), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(checking ? "按纸质备份核对顺序" : "抄写钱包助记词").font(.title2.bold())
            Text("⚠️ 此 12 词 = 钱包全部资产。抄纸备份，禁止拍照、截图或存入云端。")
                .foregroundStyle(.orange)
            if checking {
                Text(selected.count == words.count ? "核对完成" : "请选择第 \(selected.count + 1) 个词")
                    .font(.headline)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(choices, id: \.self) { index in
                        Button(words[index]) { select(index) }
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .disabled(selected.contains(index))
                    }
                }
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(words.indices, id: \.self) { index in
                        Text("\(index + 1). \(words[index])")
                            .font(.system(.title3, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                if checking {
                    Button("重新抄写") {
                        checking = false
                        selected = []
                        errorMessage = nil
                    }
                    Button("完成备份", action: onConfirm).disabled(selected.count != words.count)
                } else {
                    Button("已抄写，开始核对") {
                        choices = Array(words.indices).shuffled()
                        selected = []
                        checking = true
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }

    private func select(_ index: Int) {
        guard selected.count < words.count else { return }
        guard words[index] == words[selected.count] else {
            errorMessage = "顺序不正确，请核对纸质备份后重试。"
            return
        }
        errorMessage = nil
        selected.insert(index)
    }
}
