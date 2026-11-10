import AVFoundation
import Speech

/// Continuous English speech recognition.
/// Audio is split into short segments: a segment is "committed" after a short pause
/// (or after a max length), then a fresh recognition request starts right away.
final class SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onCommit: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let lock = NSLock()
    private var current: Segment?
    private var running = false
    private var silenceTimer: Timer?
    private var segmentStart = Date()

    private let silenceDelay: TimeInterval = 1.3
    private let maxSegment: TimeInterval = 25

    private final class Segment {
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var text = ""
        var committed = false
    }

    enum EngineError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Nhận diện giọng nói tiếng Anh hiện không khả dụng." }
    }

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    // MARK: - Start / stop (main thread)

    func start() throws {
        guard let recognizer, recognizer.isAvailable else { throw EngineError.unavailable }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        running = true
        startSegment()

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let seg = self.current
            self.lock.unlock()
            seg?.request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() {
        running = false
        silenceTimer?.invalidate()
        rotate()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        setCurrent(nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Segments

    private func setCurrent(_ seg: Segment?) {
        lock.lock(); current = seg; lock.unlock()
    }

    private func startSegment() {
        guard running, let recognizer else { return }
        let seg = Segment()
        seg.request.shouldReportPartialResults = true
        seg.request.addsPunctuation = true
        seg.request.taskHint = .dictation
        seg.task = recognizer.recognitionTask(with: seg.request) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(seg, result: result, error: error) }
        }
        segmentStart = Date()
        setCurrent(seg)
    }

    private func handle(_ seg: Segment, result: SFSpeechRecognitionResult?, error: Error?) {
        let isCurrent = seg === current

        if let result {
            seg.text = result.bestTranscription.formattedString
            if isCurrent && !seg.committed {
                onPartial?(seg.text)
                scheduleSilenceTimer()
                if Date().timeIntervalSince(segmentStart) > maxSegment {
                    rotate()
                    return
                }
            }
            if result.isFinal {
                if isCurrent { rotate() } else { commit(seg) }
                return
            }
        }

        if error != nil {
            commit(seg)
            // Recognizer stopped by itself (timeout, network…): restart it.
            if isCurrent && running {
                setCurrent(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.running, self.current == nil else { return }
                    self.startSegment()
                }
            }
        }
    }

    private func scheduleSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceDelay, repeats: false) { [weak self] _ in
            guard let self, let seg = self.current, !seg.text.isEmpty else { return }
            self.rotate()
        }
    }

    /// Commit the current segment now and start a new one immediately so no audio is lost.
    private func rotate() {
        silenceTimer?.invalidate()
        guard let seg = current else { return }
        setCurrent(nil)
        commit(seg)
        seg.request.endAudio()
        seg.task?.cancel()
        startSegment()
    }

    private func commit(_ seg: Segment) {
        guard !seg.committed else { return }
        seg.committed = true
        onPartial?("")
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onCommit?(text) }
    }
}
