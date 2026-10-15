import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CofferSettingsButton: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text(title) }
        } else {
            Button(title) {
                let selector = if #available(macOS 13, *) {
                    "showSettingsWindow:"
                } else {
                    "showPreferencesWindow:"
                }
                NSApp.sendAction(Selector(selector), to: nil, from: nil)
            }
        }
    }
}

/// Local events are handled only while this panel's own window is key.
struct CofferPanelKeyHandler: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    final class Coordinator {
        var handle: (NSEvent) -> Bool
        var monitor: Any?
        weak var view: NSView?

        init(handle: @escaping (NSEvent) -> Bool) { self.handle = handle }
    }

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard let coordinator, let window = coordinator.view?.window,
                  window.isKeyWindow, event.window === window else { return event }
            return coordinator.handle(event) ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.handle = handle }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
}

/// Keep newer navigation and form layouts while supporting macOS Monterey.
struct CofferSplitView<Sidebar: View, Content: View, Detail: View>: View {
    let sidebar: Sidebar
    let content: Content
    let detail: Detail

    init(@ViewBuilder sidebar: () -> Sidebar,
         @ViewBuilder content: () -> Content,
         @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.content = content()
        self.detail = detail()
    }

    var body: some View {
        if #available(macOS 13, *) {
            NavigationSplitView { sidebar } content: { content } detail: { detail }
        } else {
            NavigationView {
                sidebar
                content.frame(minWidth: 240)
                detail.frame(minWidth: 350)
            }
            .frame(minWidth: 850, minHeight: 500)
        }
    }
}

struct CofferNavigationStack<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        if #available(macOS 13, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
        }
    }
}

struct CofferLabeledContent<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if #available(macOS 13, *) {
            LabeledContent(title) { content }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                content
            }
        }
    }
}

extension CofferLabeledContent where Content == Text {
    init(_ title: String, value: String) {
        self.init(title) { Text(value) }
    }
}

struct CofferEmptyState: View {
    let title: String
    let systemImage: String
    let description: Text

    init(_ title: String, systemImage: String, description: Text) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    static func search(text: String) -> CofferEmptyState {
        CofferEmptyState("没有搜索结果", systemImage: "magnifyingglass",
                         description: Text(text.isEmpty ? "试试其他关键词" : "未找到与“\(text)”匹配的内容"))
    }

    var body: some View {
        if #available(macOS 14, *) {
            ContentUnavailableView(title, systemImage: systemImage, description: description)
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.secondary)
                Text(title).font(.title2.bold())
                description.foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CofferMultilineField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        if #available(macOS 13, *) {
            TextField(title, text: $text, axis: .vertical)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text).frame(minHeight: 60, maxHeight: 140)
            }
        }
    }
}

extension View {
    @ViewBuilder
    func cofferGroupedForm() -> some View {
        if #available(macOS 13, *) {
            formStyle(.grouped)
        } else {
            ScrollView { self.padding() }
        }
    }

    @ViewBuilder
    func cofferSidebarWidth(min: CGFloat, ideal: CGFloat) -> some View {
        if #available(macOS 13, *) {
            navigationSplitViewColumnWidth(min: min, ideal: ideal)
        } else {
            frame(minWidth: min, idealWidth: ideal)
        }
    }

    @ViewBuilder
    func cofferLineLimit(_ range: ClosedRange<Int>) -> some View {
        if #available(macOS 13, *) { lineLimit(range) } else { lineLimit(range.upperBound) }
    }

    @ViewBuilder
    func cofferDropStrings(_ action: @escaping ([String]) -> Bool) -> some View {
        if #available(macOS 13, *) {
            dropDestination(for: String.self) { strings, _ in action(strings) }
        } else {
            onDrop(of: [UTType.utf8PlainText], delegate: CofferStringDropDelegate(action: action))
        }
    }
}

private struct CofferStringDropDelegate: DropDelegate {
    let action: ([String]) -> Bool

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.utf8PlainText]).first,
              provider.canLoadObject(ofClass: NSString.self) else { return false }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let string = value as? String else { return }
            DispatchQueue.main.async { _ = action([string]) }
        }
        return true
    }
}
