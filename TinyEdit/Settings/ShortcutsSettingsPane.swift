import SwiftUI

/// Every keyboard shortcut, grouped as in `ShortcutCatalog`. Read-only: the shortcuts are fixed.
struct ShortcutsSettingsPane: View {
    var body: some View {
        Form {
            ForEach(ShortcutCatalog.groups.indices, id: \.self) { g in
                let group = ShortcutCatalog.groups[g]
                Section {
                    ForEach(group.items.indices, id: \.self) { i in
                        let item = group.items[i]
                        LabeledContent {
                            HStack(spacing: 4) {
                                ForEach(item.keys.indices, id: \.self) { k in
                                    if item.isRange, k > 0 {
                                        Text(verbatim: "–").foregroundStyle(Color.textSecondary)
                                    }
                                    KeyCap(text: item.keys[k].displayString)
                                }
                            }
                        } label: {
                            Text(item.title)
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 6)
            .frame(minWidth: 26, minHeight: 20)
            .background(Color.controlRaised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.separator))
    }
}
