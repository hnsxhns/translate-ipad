import SwiftUI

struct MainView: View {
    @Bindable var auth: AuthStore
    @State private var session: LiveSession

    init(auth: AuthStore, session: LiveSession) {
        self.auth = auth
        _session = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            GeometryReader { geo in
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        englishPanel.frame(width: geo.size.width / 2)
                        Divider()
                        vietnamesePanel
                    }
                    .frame(height: geo.size.height * 0.75)
                    Divider()
                    summaryPanel.frame(height: geo.size.height * 0.25)
                }
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: Top bar with the single ON/OFF button

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("Live Translate").font(.headline)
            if session.isRunning {
                Label("Đang nghe", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
            if let err = session.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Menu {
                Text(auth.userLabel)
                Button("Xoá nội dung", systemImage: "trash") { session.clear() }
                    .disabled(session.isRunning)
                Button("Đăng xuất", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    if session.isRunning { session.stop() }
                    auth.logout()
                }
            } label: {
                Image(systemName: "person.crop.circle").font(.title3)
            }
            Button {
                Task { await session.toggle() }
            } label: {
                Text(session.isRunning ? "ON" : "OFF")
                    .font(.headline.monospaced())
                    .frame(width: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(session.isRunning ? .green : .gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Panels

    private var englishPanel: some View {
        Panel(title: "English", scrollKey: session.entries.count + session.partial.count) {
            ForEach(session.entries) { Text($0.en) }
            if !session.partial.isEmpty {
                Text(session.partial).foregroundStyle(.secondary)
            }
        }
    }

    private var vietnamesePanel: some View {
        Panel(title: "Tiếng Việt", scrollKey: session.entries.reduce(0) { $0 + $1.vi.count }) {
            ForEach(session.entries) { entry in
                if entry.vi.isEmpty {
                    Text("…").foregroundStyle(.tertiary)
                } else {
                    Text(entry.vi)
                }
            }
        }
    }

    private var summaryPanel: some View {
        Panel(title: session.isSummarizing ? "Ý chính (đang cập nhật…)" : "Ý chính",
              scrollKey: 0, autoScroll: false) {
            if session.summary.isEmpty {
                Text("Các ý chính sẽ hiện ở đây khi bắt đầu nghe.")
                    .foregroundStyle(.tertiary)
            } else {
                Text(session.summary)
            }
        }
        .background(Color(.secondarySystemBackground))
    }
}

/// A titled, scrollable text column that follows new content.
private struct Panel<Content: View>: View {
    let title: String
    let scrollKey: Int
    var autoScroll = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        content
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .font(.title3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .onChange(of: scrollKey) {
                    guard autoScroll else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
