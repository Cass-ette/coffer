import SwiftUI
import CofferCore

private struct GroupIcon: Identifiable {
    let symbol: String
    let name: String
    var id: String { symbol }
    init(_ symbol: String, _ name: String) { self.symbol = symbol; self.name = name }
}

private struct GroupIconCategory: Identifiable {
    let name: String
    let icons: [GroupIcon]
    var id: String { name }

    static let all: [Self] = [
        .init(name: "通用", icons: [
            .init("folder", "文件夹"), .init("folder.fill", "实心文件夹"), .init("tray", "收件箱"),
            .init("archivebox", "归档"), .init("square.stack", "集合"), .init("tag", "标签"),
            .init("star", "星标"), .init("heart", "喜爱"), .init("bookmark", "书签"),
            .init("flag", "旗帜"), .init("pin", "置顶"), .init("circle.grid.2x2", "分类")
        ]),
        .init(name: "开发与设备", icons: [
            .init("terminal", "终端 SSH"), .init("server.rack", "服务器"), .init("network", "网络"),
            .init("externaldrive", "外置硬盘"), .init("internaldrive", "磁盘"), .init("cpu", "芯片"),
            .init("desktopcomputer", "台式电脑"), .init("laptopcomputer", "笔记本电脑"), .init("iphone", "手机"),
            .init("wifi", "无线网络"), .init("cloud", "云服务"), .init("chevron.left.forwardslash.chevron.right", "代码")
        ]),
        .init(name: "安全与身份", icons: [
            .init("lock.shield", "安全保险库"), .init("lock", "锁"), .init("key", "密钥"),
            .init("shield", "盾牌"), .init("checkmark.shield", "安全验证"), .init("person.badge.key", "身份凭证"),
            .init("touchid", "指纹"), .init("faceid", "面容"), .init("qrcode", "二维码"),
            .init("eye.slash", "隐私"), .init("lock.doc", "加密文件"), .init("signature", "签名")
        ]),
        .init(name: "工作与学习", icons: [
            .init("briefcase", "工作"), .init("building.2", "公司"), .init("building.columns", "机构"),
            .init("graduationcap", "学校"), .init("book", "学习"), .init("doc.text", "文档"),
            .init("chart.bar", "统计"), .init("calendar", "日历"), .init("checklist", "清单"),
            .init("person.2", "团队"), .init("envelope", "邮箱"), .init("lightbulb", "灵感")
        ]),
        .init(name: "资产与服务", icons: [
            .init("wallet.pass", "钱包"), .init("creditcard", "银行卡"), .init("banknote", "现金"),
            .init("bitcoinsign.circle", "加密资产"), .init("dollarsign.circle", "财务"), .init("cart", "购物"),
            .init("bag", "商店"), .init("shippingbox", "包裹"), .init("globe", "网站"),
            .init("link", "链接"), .init("bolt", "电力"), .init("gearshape", "设置")
        ]),
        .init(name: "生活与出行", icons: [
            .init("house", "家庭"), .init("person", "个人"), .init("car", "汽车"),
            .init("airplane", "飞机"), .init("tram", "公共交通"), .init("bicycle", "自行车"),
            .init("map", "地图"), .init("location", "位置"), .init("suitcase", "旅行"),
            .init("camera", "摄影"), .init("gamecontroller", "游戏"), .init("cross.case", "健康")
        ])
    ]
}

struct GroupIconPicker: View {
    @Binding var selection: String
    @State private var search = ""
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedName: String {
        GroupIconCategory.all.flatMap(\.icons).first { $0.symbol == selection }?.name ?? "当前图标"
    }
    private func matches(_ icon: GroupIcon, category: String) -> Bool {
        query.isEmpty || (icon.name + " " + icon.symbol + " " + category).localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择图标").font(.subheadline.weight(.semibold))
                Spacer()
                Label(selectedName, systemImage: selection).foregroundStyle(.tint)
            }
            TextField("搜索图标，如服务器、学校、钱包…", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(GroupIconCategory.all) { category in
                        let icons = category.icons.filter { matches($0, category: category.name) }
                        if !icons.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(category.name).font(.caption).foregroundStyle(.secondary)
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                                    ForEach(icons) { icon in
                                        Button { selection = icon.symbol } label: {
                                            Image(systemName: icon.symbol)
                                                .font(.title2)
                                                .frame(maxWidth: .infinity).frame(height: 42)
                                                .background(selection == icon.symbol ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.08),
                                                            in: RoundedRectangle(cornerRadius: 8))
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(selection == icon.symbol ? Color.accentColor : .clear, lineWidth: 1.5)
                                                }
                                        }
                                        .buttonStyle(.plain).help(icon.name)
                                        .accessibilityLabel(icon.name)
                                        .accessibilityAddTraits(selection == icon.symbol ? .isSelected : [])
                                    }
                                }
                            }
                        }
                    }
                    if !GroupIconCategory.all.contains(where: { category in
                        category.icons.contains { matches($0, category: category.name) }
                    }) {
                        CofferEmptyState.search(text: search)
                    }
                }.padding(2)
            }.frame(height: 280)
        }
    }
}

struct ChangeGroupIconSheet: View {
    let group: CofferCore.Group
    @EnvironmentObject private var unlock: UnlockService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIcon: String
    @State private var saveError: String?

    init(group: CofferCore.Group) {
        self.group = group
        _selectedIcon = State(initialValue: group.symbolName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("更换「\(group.name)」的图标").font(.headline)
            GroupIconPicker(selection: $selectedIcon)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(!unlock.isUnlocked)
            }
        }.padding(22).frame(width: 440)
        .onChange(of: unlock.isUnlocked) { unlocked in if !unlocked { dismiss() } }
    }

    private func save() {
        guard unlock.isUnlocked, var document = unlock.document,
              let index = document.groups.firstIndex(where: { $0.id == group.id }) else {
            saveError = "分组已不可用，请关闭后重试"
            return
        }
        let previous = document.groups[index].symbolName
        document.groups[index].symbolName = selectedIcon
        unlock.document = document
        do {
            try unlock.persist()
            dismiss()
        } catch {
            document.groups[index].symbolName = previous
            unlock.document = document
            saveError = "图标保存失败：\(error.localizedDescription)"
        }
    }
}
