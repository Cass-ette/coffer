import SwiftUI
import CofferCore

struct EntryListView: View {
    let entries: [Entry]
    @Binding var selection: Entry.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.type.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).lineLimit(1)
                        if !entry.subtitle.isEmpty {
                            Text(entry.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if entry.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.vertical, 2)
                .tag(entry.id)
                .draggable(entry.id.uuidString)
            }
        }
        .listStyle(.inset)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView.search(text: "")
            }
        }
    }
}
