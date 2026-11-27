import SwiftUI

/// The full changelog: the newest build open, every earlier build collapsed under it.
struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var open: Set<Int> = []

    private var shown: [WhatsNewRelease] {
        let top = WhatsNew.newest(forBuild: WhatsNew.currentBuild)
        return WhatsNew.releases.filter { top == 0 || $0.build <= top }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                    if i == 0 {
                        Section {
                            ForEach(r.items) { WhatsNewRow(item: $0) }
                        } header: { HMHeader("Build \(r.build)") }
                    } else {
                        Section {
                            DisclosureGroup(isExpanded: Binding(
                                get: { open.contains(r.build) },
                                set: { if $0 { open.insert(r.build) } else { open.remove(r.build) } })) {
                                ForEach(r.items) { WhatsNewRow(item: $0) }
                            } label: {
                                HStack {
                                    Text("Build \(r.build)").font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(r.items.count)").font(.caption).foregroundStyle(HMDesign.text2)
                                }
                            }
                        }
                    }
                }
            }
            .hmCanvas()
            .navigationTitle("What's new")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct WhatsNewRow: View {
    let item: WhatsNewItem

    var body: some View {
        Label {
            Text(item.text).font(.subheadline)
        } icon: {
            Image(systemName: item.symbol).foregroundStyle(HMDesign.accent)
        }
    }
}
