import Foundation
import Observation
import UIKit

/// Drives one listening session: speech → English text → Vietnamese translation → key takeaways.
@MainActor
@Observable
final class LiveSession {
    struct Entry: Identifiable {
        let id = UUID()
        var en: String
        var vi: String = ""
    }

    var entries: [Entry] = []
    var partial = ""
    var summary = ""
    var isRunning = false
    var isSummarizing = false
    var errorMessage: String?

    private let engine = SpeechEngine()
    private let client: ClaudeClient
    private var translateChain: Task<Void, Never>?
    private var summarizedCount = 0
    private var lastSummaryAt = Date.distantPast
    @ObservationIgnored private var summaryBuffer = ""

    init(apiKey: String) {
        client = ClaudeClient(apiKey: apiKey)
        engine.onPartial = { [weak self] text in self?.partial = text }
        engine.onCommit = { [weak self] text in self?.addSegment(text) }
    }

    func toggle() async {
        if isRunning { stop() } else { await start() }
    }

    func start() async {
        errorMessage = nil
        guard await SpeechEngine.requestPermissions() else {
            errorMessage = "Cần cấp quyền Micro và Nhận dạng giọng nói trong Cài đặt."
            return
        }
        do {
            try engine.start()
            isRunning = true
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
        partial = ""
        UIApplication.shared.isIdleTimerDisabled = false
        // Final summary once all pending translations are done.
        let chain = translateChain
        Task {
            await chain?.value
            if self.entries.count > self.summarizedCount { await self.summarize() }
        }
    }

    func clear() {
        guard !isRunning else { return }
        entries = []
        summary = ""
        summarizedCount = 0
    }

    // MARK: - Translation (serial, in order)

    private func addSegment(_ text: String) {
        entries.append(Entry(en: text))
        let id = entries[entries.count - 1].id
        let previous = translateChain
        translateChain = Task {
            await previous?.value
            await self.translate(id: id)
            self.maybeSummarize()
        }
    }

    private func translate(id: UUID) async {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let text = entries[idx].en
        let context = entries[max(0, idx - 3)..<idx].map(\.en).joined(separator: " ")

        let system = """
        You are a live interpreter. Translate the English speech segment the user sends into natural, fluent Vietnamese.
        The text comes from speech recognition and may contain small recognition errors; fix them silently using context.
        Output only the Vietnamese translation of the NEW segment: no notes, no quotes, no English.
        Latency-sensitive; begin your visible answer immediately.
        """
        let user = context.isEmpty
            ? "NEW segment:\n\(text)"
            : "Previous context (do not translate):\n\(context)\n\nNEW segment:\n\(text)"

        do {
            try await client.stream(system: system, user: user, effort: "low", maxTokens: 4000) { chunk in
                await MainActor.run { self.appendTranslation(chunk, to: id) }
            }
        } catch {
            appendTranslation("[Lỗi dịch: \(error.localizedDescription)]", to: id)
        }
    }

    private func appendTranslation(_ chunk: String, to id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].vi += chunk
    }

    // MARK: - Key takeaways

    private func maybeSummarize() {
        guard !isSummarizing,
              entries.count > summarizedCount,
              Date().timeIntervalSince(lastSummaryAt) > 15 || summarizedCount == 0 else { return }
        Task { await summarize() }
    }

    private func summarize() async {
        guard !isSummarizing else { return }
        isSummarizing = true
        defer { isSummarizing = false }

        let count = entries.count
        let transcript = entries.map(\.en).joined(separator: " ")
        let system = """
        You summarize a live English talk for a Vietnamese audience.
        Write the key takeaways in Vietnamese as a short bullet list (3–7 bullets, each starting with "• ").
        Each bullet is one concise sentence with a concrete idea from the talk. No title, no intro, no closing remarks.
        """
        summaryBuffer = ""
        do {
            try await client.stream(system: system,
                                    user: "Transcript so far:\n\(transcript)",
                                    effort: "medium",
                                    maxTokens: 8000) { chunk in
                await MainActor.run {
                    self.summaryBuffer += chunk
                    self.summary = self.summaryBuffer
                }
            }
            summarizedCount = count
            lastSummaryAt = Date()
        } catch {
            if summary.isEmpty { summary = "[Lỗi tóm tắt: \(error.localizedDescription)]" }
            lastSummaryAt = Date()
        }
    }
}
