import Foundation
import Observation
import UIKit

/// One listening session, same behaviour as the Windows app (LiveTranslator):
///  - English: live words (grey) + finished text, a new line after each sentence.
///  - Vietnamese: finished sentences are batched and translated in order (Claude, effort low).
///    An unfinished sentence waits at most `sendAfter` seconds (or 40 words).
///  - Key takeaways: refreshed every `summaryEvery` seconds while there is new text, and once more on OFF.
///  - Chat: ask Claude about what is being heard (multi-turn, knows transcript + translation + takeaways).
@MainActor
@Observable
final class LiveSession {
    struct ChatMessage: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var isError = false
    }

    // English pane: finished paragraphs (one per sentence) + live words.
    var englishLines: [String] = []
    var partial = ""
    // Vietnamese pane: one paragraph per translated batch.
    var vietnamese: [String] = []
    var summary = ""
    var isSummarizing = false
    var chat: [ChatMessage] = []
    var chatBusy = false

    var isRunning = false
    var status = "Nhấn ON để bắt đầu."
    var statusIsError = false

    // Settings (match the Windows app).
    private let sendAfter: TimeInterval = 6
    private let summaryEvery: TimeInterval = 25

    private let engine = SpeechEngine()
    private let client: ClaudeClient
    @ObservationIgnored private var transcript: [String] = []
    @ObservationIgnored private var pendingEN = ""
    @ObservationIgnored private var pendingSince = Date()
    @ObservationIgnored private var translateQueue: [String] = []
    @ObservationIgnored private var translating = false
    @ObservationIgnored private var history: [(en: String, vi: String)] = []
    @ObservationIgnored private var lastSummaryLength = 0
    @ObservationIgnored private var lastSummaryAt = Date()
    @ObservationIgnored private var summaryPending = false
    @ObservationIgnored private var chatHistory: [[String: String]] = []
    @ObservationIgnored private var ticker: Timer?

    init(apiKey: String) {
        client = ClaudeClient(apiKey: apiKey)
        engine.onPartial = { [weak self] text in self?.partial = text }
        engine.onCommit = { [weak self] text in self?.onEnglish(text) }
    }

    // MARK: - ON / OFF

    func toggle() async {
        if isRunning { stop() } else { await start() }
    }

    func start() async {
        guard await SpeechEngine.requestPermissions() else {
            setStatus("Cần cấp quyền Micro và Nhận dạng giọng nói trong Cài đặt.", error: true)
            return
        }
        do {
            try engine.start()
            isRunning = true
            UIApplication.shared.isIdleTimerDisabled = true
            setStatus("Đang nghe... (nói tiếng Anh)")
            lastSummaryAt = Date()
            startTicker()
        } catch {
            setStatus("Lỗi micro: \(error.localizedDescription)", error: true)
        }
    }

    func stop() {
        engine.stop()              // commits the last words
        isRunning = false
        partial = ""
        UIApplication.shared.isIdleTimerDisabled = false
        sendSentences(force: true) // translate whatever is left
        ticker?.invalidate()
        ticker = nil
        setStatus("Đã tắt.")
        summarize()                // final takeaways
    }

    func clear() {
        guard !isRunning, !translating, !chatBusy else { return }
        englishLines = []
        vietnamese = []
        summary = ""
        chat = []
        chatHistory = []
        transcript = []
        history = []
        pendingEN = ""
        lastSummaryLength = 0
        setStatus("Nhấn ON để bắt đầu.")
    }

    private func setStatus(_ text: String, error: Bool = false) {
        status = text
        statusIsError = error
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                self.sendSentences()
                if Date().timeIntervalSince(self.lastSummaryAt) >= self.summaryEvery {
                    self.summarize()
                }
            }
        }
    }

    // MARK: - English

    private func onEnglish(_ text: String) {
        transcript.append(text)
        appendEnglish(text)
        if pendingEN.isEmpty { pendingSince = Date() }
        pendingEN += " " + text
        sendSentences()
    }

    /// Finished text in black; a new line after each sentence (like the Windows app).
    private func appendEnglish(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if englishLines.isEmpty || Self.endsSentence(englishLines[englishLines.count - 1]) {
            englishLines.append(t)
        } else {
            englishLines[englishLines.count - 1] += " " + t
        }
    }

    private static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return true }
        return ".?!".contains(last)
    }

    // MARK: - Translation

    /// Send finished sentences to the translator; an unfinished sentence waits (max `sendAfter` s or 40 words).
    private func sendSentences(force: Bool = false) {
        let text = pendingEN.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var send = text
        var rest = ""
        let longWait = Date().timeIntervalSince(pendingSince) >= sendAfter
        if !(force || longWait || text.split(separator: " ").count > 40) {
            let regex = try! NSRegularExpression(pattern: "[.!?](?=\\s|$)")
            let ns = text as NSString
            guard let last = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else {
                return
            }
            let cut = last.range.location + last.range.length
            send = ns.substring(to: cut)
            rest = ns.substring(from: cut)
        }
        translateQueue.append(send.trimmingCharacters(in: .whitespaces))
        pendingEN = rest.trimmingCharacters(in: .whitespaces)
        pendingSince = Date()
        pumpTranslations()
    }

    private func pumpTranslations() {
        guard !translating, !translateQueue.isEmpty else { return }
        translating = true
        let en = translateQueue.joined(separator: " ")
        translateQueue = []
        let context = history.suffix(4).map { "EN: \($0.en)\nVI: \($0.vi)" }.joined(separator: "\n")
        let prompt = (context.isEmpty ? "" : "Previous context (already translated, do not repeat):\n\(context)\n\n")
            + "NEW text to translate:\n\(en)"
        let system = """
        You are a live interpreter. Translate the English speech transcript the user sends into natural, \
        fluent Vietnamese. The transcript comes from speech recognition, so silently fix obvious recognition \
        errors. Output ONLY the Vietnamese translation of the NEW text, no notes, no quotes, no English.
        """
        vietnamese.append("")
        let index = vietnamese.count - 1

        Task {
            var vi = ""
            do {
                vi = try await client.stream(system: system, user: prompt, effort: "low", maxTokens: 4000) { chunk in
                    await MainActor.run { if index < self.vietnamese.count { self.vietnamese[index] += chunk } }
                }
            } catch {
                if index < vietnamese.count { vietnamese[index] += "[chưa dịch được đoạn này]" }
                setStatus(ClaudeClient.friendlyError(error), error: true)
            }
            history.append((en, vi.trimmingCharacters(in: .whitespacesAndNewlines)))
            translating = false
            pumpTranslations()
        }
    }

    // MARK: - Key takeaways

    private func summarize() {
        lastSummaryAt = Date()
        if isSummarizing { summaryPending = true; return }
        let text = transcript.joined(separator: " ")
        guard text.split(separator: " ").count >= 15, text.count != lastSummaryLength else { return }
        lastSummaryLength = text.count
        isSummarizing = true
        let system = """
        You summarize a live talk/conversation for a Vietnamese listener. Given the English transcript so far, \
        write the KEY TAKEAWAYS in Vietnamese: 3-7 short bullet points starting with '• ', most important first, \
        covering the whole transcript so far. Output only the bullets.
        """
        Task {
            do {
                let out = try await client.stream(system: system, user: "Transcript:\n\(text)",
                                                  effort: "medium", maxTokens: 8000) { _ in }
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { summary = trimmed }
            } catch {
                lastSummaryLength = 0  // try again next round
                setStatus(ClaudeClient.friendlyError(error), error: true)
            }
            isSummarizing = false
            if summaryPending {
                summaryPending = false
                summarize()
            }
        }
    }

    // MARK: - Ask Claude

    func ask(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chatBusy else { return }
        chatBusy = true
        chat.append(ChatMessage(role: .user, text: question))
        chat.append(ChatMessage(role: .assistant, text: ""))
        let index = chat.count - 1

        let en = String(transcript.joined(separator: " ").suffix(40_000))
        let vi = String(history.map(\.vi).joined(separator: "\n").suffix(20_000))
        let context = """
        <transcript_english>
        \(en.isEmpty ? "(chưa có)" : en)
        </transcript_english>
        <translation_vietnamese>
        \(vi.isEmpty ? "(chưa có)" : vi)
        </translation_vietnamese>
        <key_takeaways>
        \(summary.isEmpty ? "(chưa có)" : summary)
        </key_takeaways>
        """
        // The latest session context rides on the newest question, so earlier turns stay unchanged.
        let messages = Array(chatHistory.suffix(20))
            + [["role": "user", "content": "\(context)\n\nCâu hỏi của tôi: \(question)"]]
        let system = """
        You are Claude, helping a Vietnamese user who is listening to a live English talk or conversation. \
        The app gives you the speech-recognition transcript so far (it may contain recognition errors), its \
        Vietnamese translation, and the current key takeaways. Answer the user's questions about it, or any \
        other question they ask. Reply in Vietnamese unless the user writes in another language or asks \
        otherwise. Be clear and concise; plain text, short bullet points when helpful (no Markdown headings or \
        tables). If the transcript doesn't contain the answer, say so and answer from general knowledge if \
        appropriate.
        """

        Task {
            var answer = ""
            do {
                answer = try await client.stream(system: system, messages: messages,
                                                 effort: "medium", maxTokens: 8000) { chunk in
                    await MainActor.run { if index < self.chat.count { self.chat[index].text += chunk } }
                }
            } catch {
                if index < chat.count {
                    chat[index].text += "[\(ClaudeClient.friendlyError(error))]"
                    chat[index].isError = true
                }
            }
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chatHistory += [["role": "user", "content": question],
                                ["role": "assistant", "content": trimmed]]
            }
            chatBusy = false
        }
    }

    // MARK: - Demo content (simulator screenshots in CI only)

    func loadDemo() {
        englishLines = [
            "Today I want to talk about how small habits shape long-term success.",
            "Most people overestimate what they can do in a day, but underestimate what they can do in a year.",
        ]
        partial = "So the first habit is to write down"
        vietnamese = [
            "Hôm nay tôi muốn nói về việc những thói quen nhỏ định hình thành công lâu dài như thế nào.",
            "Hầu hết mọi người đánh giá quá cao những gì họ làm được trong một ngày, nhưng lại đánh giá thấp những gì họ làm được trong một năm.",
        ]
        summary = "• Thói quen nhỏ quyết định thành công lâu dài.\n• Đừng đánh giá thấp tiến bộ tích luỹ trong một năm."
        chat = [
            ChatMessage(role: .user, text: "Diễn giả đang nói về chủ đề gì?"),
            ChatMessage(role: .assistant, text: "Diễn giả nói về sức mạnh của những thói quen nhỏ và sự kiên trì theo thời gian."),
        ]
    }
}
