import SwiftUI

struct BannerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let banner = appState.banner {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.warning)
                Text(banner.text).font(.system(size: 12))
                Spacer()
                ForEach(banner.actions) { a in
                    Button(a.title) { appState.applyConflictAction(a.action) }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.warningBackground)
            ThemeDivider()
        }
    }
}

struct ToastView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let toast = appState.toast {
            Text(toast.text)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(toast.isError ? Color.error.opacity(0.6) : Color.separator))
                .padding(.bottom, 12)
                .onTapGesture { appState.dismissToast() }
                .transition(.opacity)
                .accessibilityLabel(toast.text)
        }
    }
}
