import SwiftUI

/// Same layout as the Windows app (dividers can be dragged):
///   left column : English (3/4)            | right column: Tiếng Việt (~1/2)
///                 Key takeaways (1/4)       |               Claude answers (~1/3)
///                                           |               prompt box (rest)
struct MainView: View {
    @Bindable var auth: AuthStore
    @State private var session: LiveSession
    @State private var leftSplits: [CGFloat] = [0.75]
    @State private var rightSplits: [CGFloat] = [0.50, 0.84]
    @State private var question = ""
    @FocusState private var promptFocused: Bool

    private static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

    init(auth: AuthStore, session: LiveSession) {
        self.auth = auth
        _session = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 6) {
                SplitColumn(splits: $leftSplits, panes: [AnyView(englishPanel), AnyView(summaryPanel)])
                SplitColumn(splits: $rightSplits,
                            panes: [AnyView(vietnamesePanel), AnyView(chatPanel), AnyView(promptPanel)])
            }
            .padding(6)
        }
        .background(Color(.systemGroupedBackground))
        .task {
            if ProcessInfo.processInfo.arguments.contains("-demo") {
                session.loadDemo()
            } else {
                await auth.revalidateSavedLogin()
            }
        }
    }

    // MARK: Top bar: status · menu · ON/OFF

    private var topBar: some View {
        HStack(spacing: 12) {
            if session.isRunning {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
            Text(session.status)
                .font(.callout)
                .foregroundStyle(session.statusIsError ? Color.red : Color.secondary)
                .lineLimit(2)
            Spacer()
            Menu {
                if !auth.userLabel.isEmpty { Text(auth.userLabel) }
                Text("Live Translate v\(AuthStore.appVersion)")
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
        .background(.bar)
    }

    // MARK: Panes

    private var englishPanel: some View {
        Pane(title: "English (nhận diện giọng nói)",
             scrollKey: session.englishLines.count * 1000 + session.partial.count) {
            ForEach(Array(session.englishLines.dropLast().enumerated()), id: \.offset) { _, line in
                Text(line)
            }
            // last line + live words in grey
            if session.englishLines.last != nil || !session.partial.isEmpty {
                (Text(session.englishLines.last.map { $0 + " " } ?? "")
                 + Text(session.partial).foregroundStyle(Color.secondary))
            }
        }
    }

    private var vietnamesePanel: some View {
        Pane(title: "Tiếng Việt (bản dịch)",
             scrollKey: session.vietnamese.count * 100_000 + (session.vietnamese.last?.count ?? 0)) {
            ForEach(Array(session.vietnamese.enumerated()), id: \.offset) { _, para in
                Text(para.isEmpty ? "…" : para)
                    .foregroundStyle(para.isEmpty ? Color.secondary : Color.primary)
            }
        }
    }

    private var summaryPanel: some View {
        Pane(title: session.isSummarizing ? "Ý chính / Key takeaways (đang cập nhật…)" : "Ý chính / Key takeaways",
             scrollKey: 0, autoScroll: false) {
            Text(session.summary.isEmpty ? "Các ý chính sẽ hiện ở đây sau khi nghe được một đoạn." : session.summary)
                .foregroundStyle(session.summary.isEmpty ? Color.secondary : Color.primary)
        }
    }

    private var chatPanel: some View {
        Pane(title: "Claude trả lời",
             scrollKey: session.chat.count * 100_000 + (session.chat.last?.text.count ?? 0)) {
            if session.chat.isEmpty {
                Text("Hỏi Claude về nội dung đang nghe ở ô bên dưới.")
                    .foregroundStyle(Color.secondary)
            }
            ForEach(session.chat) { msg in
                let who = msg.role == .user
                    ? Text("Bạn: ").bold().foregroundStyle(Color.blue)
                    : Text("Claude: ").bold().foregroundStyle(Self.accent)
                (who + Text(msg.text.isEmpty && session.chatBusy ? "…" : msg.text)
                    .foregroundStyle(msg.isError ? Color.red : Color.primary))
            }
        }
    }

    private var promptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Hỏi Claude về nội dung đang nghe  (Return: gửi · Shift+Return: xuống dòng)")
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Nhập câu hỏi…", text: $question, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($promptFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        sendQuestion()
                        return .handled
                    }
                Button(action: sendQuestion) {
                    Text(session.chatBusy ? "..." : "Gửi ➤").bold()
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.accent)
                .disabled(session.chatBusy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sendQuestion() {
        guard !session.chatBusy else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        question = ""
        session.ask(q)
        promptFocused = true
    }
}

// MARK: - Building blocks

private struct PaneHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.footnote.bold())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
    }
}

/// A titled, scrollable text pane that follows new content.
private struct Pane<Content: View>: View {
    let title: String
    let scrollKey: Int
    var autoScroll = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: title)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        content
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .font(.title3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .onChange(of: scrollKey) {
                    guard autoScroll else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Vertical stack of panes with draggable dividers.
/// `splits` are the divider positions as fractions of the height (e.g. [0.5, 0.84] for 3 panes).
private struct SplitColumn: View {
    @Binding var splits: [CGFloat]
    let panes: [AnyView]
    @State private var dragStart: CGFloat?

    private let handle: CGFloat = 12
    private let minPane: CGFloat = 60

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let edges = [0] + splits + [1]
            VStack(spacing: 0) {
                ForEach(panes.indices, id: \.self) { i in
                    let isLast = i == panes.count - 1
                    panes[i]
                        .frame(height: max(0, (edges[i + 1] - edges[i]) * h - (isLast ? 0 : handle)))
                    if !isLast {
                        grip(index: i, height: h)
                    }
                }
            }
        }
    }

    private func grip(index i: Int, height h: CGFloat) -> some View {
        ZStack {
            Color.clear
            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 44, height: 4)
        }
        .frame(height: handle)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard h > 0 else { return }
                    let start = dragStart ?? splits[i]
                    if dragStart == nil { dragStart = start }
                    let minGap = (minPane + handle) / h
                    let lower = (i == 0 ? 0 : splits[i - 1]) + minGap
                    let upper = (i == splits.count - 1 ? 1 : splits[i + 1]) - minGap
                    guard lower < upper else { return }
                    splits[i] = min(max(start + value.translation.height / h, lower), upper)
                }
                .onEnded { _ in dragStart = nil }
        )
        .hoverEffect(.highlight)
    }
}
