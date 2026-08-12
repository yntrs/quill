import AppKit
import AVFoundation
import Foundation
import Speech

/// On-device (when available) Greek dictation via Apple's Speech framework.
///
/// xAI's streaming STT is weak on Modern Greek. Apple's `el-GR` model is trained
/// for Greek and, on this Mac, supports on-device recognition — so we use it
/// whenever the user picks Greek. English and other languages stay on Grok STT.
final class AppleSTTClient: NSObject, StreamingTranscriber {

    var onText: (String) -> Void = { _ in }
    var onReady: () -> Void = {}
    var onComplete: (String) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var didFinish = false
    private var finishRequested = false
    /// Utterances already locked in. Apple starts a new utterance after a short
    /// pause — if we only kept the latest `formattedString` the previous words vanished.
    private var committed = ""
    private var livePartial = ""
    private var bestText = ""
    private var doneTimer: Timer?
    private var languageId = "el-GR"
    /// Bumps on every new recognition task so a dying task's late error cannot
    /// restart us in a loop or wipe the next utterance.
    private var generation = 0

    /// PCM16 mono 16 kHz — same wire format the recorder already produces.
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16_000,
                                          channels: 1,
                                          interleaved: true)!

    static func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                done(status == .authorized)
            }
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func recognizer(for language: String) -> SFSpeechRecognizer? {
        let id: String
        switch language {
        case "el": id = "el-GR"
        case "en": id = "en-US"
        default:   id = language.contains("-") ? language : "\(language)-\(language.uppercased())"
        }
        return SFSpeechRecognizer(locale: Locale(identifier: id))
    }

    /// Greek (and anything else we route here) — prefer on-device when the asset exists.
    func connect(language: String = "el") {
        didFinish = false
        finishRequested = false
        committed = ""
        livePartial = ""
        bestText = ""
        languageId = language == "el" ? "el-GR" : language

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageId)),
              recognizer.isAvailable
        else {
            DispatchQueue.main.async { [weak self] in
                self?.onFailure("Apple speech recognition is not available for this language")
            }
            return
        }
        self.recognizer = recognizer
        startTask(of: recognizer)
        DispatchQueue.main.async { [weak self] in self?.onReady() }
    }

    private func startTask(of recognizer: SFSpeechRecognizer) {
        generation += 1
        let gen = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = Self.englishContextHints
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            Log.write("Apple STT: on-device \(languageId) committed=\(committed.count)ch")
        } else {
            Log.write("Apple STT: network \(languageId) committed=\(committed.count)ch")
        }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, !self.didFinish, self.generation == gen else { return }

            if let result {
                self.apply(result)
                if result.isFinal, self.finishRequested {
                    self.complete()
                    return
                }
            }

            if let error {
                let ns = error as NSError
                Log.write("Apple STT error: \(ns.domain) code=\(ns.code) — \(error.localizedDescription) bestText=\(self.bestText.count)ch finish=\(self.finishRequested)")
                if self.finishRequested {
                    if !self.bestText.isEmpty {
                        self.complete()
                    } else {
                        DispatchQueue.main.async {
                            self.onFailure(Self.friendlyMessage(for: error))
                        }
                    }
                    return
                }
                // Mid-dictation pause: Apple ends the *utterance*, not the session.
                // Commit what we have and keep listening on a fresh task.
                if !self.livePartial.isEmpty {
                    self.committed = Self.merge(self.committed, self.livePartial)
                    self.livePartial = ""
                    self.publish()
                }
                if let recognizer = self.recognizer {
                    self.startTask(of: recognizer)
                }
            }
        }
    }

    private func apply(_ result: SFSpeechRecognitionResult) {
        let text = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isFinal {
            if !text.isEmpty {
                committed = Self.merge(committed, text)
            }
            livePartial = ""
            publish()
            return
        }

        guard !text.isEmpty else { return }

        if !livePartial.isEmpty, !Self.isContinuation(old: livePartial, new: text) {
            committed = Self.merge(committed, livePartial)
        }
        // Don't keep a live tail that is already the end of committed
        // (finish() or isFinal already stored it).
        if Self.alreadyHas(committed, text) {
            livePartial = ""
        } else {
            livePartial = text
        }
        publish()
    }

    private func publish() {
        if livePartial.isEmpty {
            bestText = committed
        } else if Self.alreadyHas(committed, livePartial) {
            bestText = committed
        } else if committed.isEmpty {
            bestText = livePartial
        } else if livePartial.hasPrefix(committed) {
            bestText = livePartial
        } else {
            bestText = Self.join(committed, livePartial)
        }
        let snapshot = bestText
        guard !snapshot.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onText(snapshot) }
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if a.hasSuffix(" ") || b.hasPrefix(" ") { return a + b }
        return a + " " + b
    }

    /// Append `incoming` only if it is actually new. Apple often re-sends the
    /// same utterance as isFinal after we already committed the live partial —
    /// that was producing "grok grok" → "grok grok grok grok".
    private static func merge(_ committed: String, _ incoming: String) -> String {
        let a = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if alreadyHas(a, b) { return a }
        if b.hasPrefix(a) { return b }
        return join(a, b)
    }

    private static func alreadyHas(_ committed: String, _ incoming: String) -> Bool {
        let a = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        if a.hasSuffix(b) { return true }
        // Case-insensitive suffix for "Grok" vs "grok"
        let al = a.lowercased()
        let bl = b.lowercased()
        return al == bl || al.hasSuffix(bl)
    }

    /// Same utterance growing/revising vs a brand-new sentence after a pause.
    private static func isContinuation(old: String, new: String) -> Bool {
        if new.hasPrefix(old) || old.hasPrefix(new) { return true }
        let ol = old.lowercased(), nl = new.lowercased()
        if nl.hasPrefix(ol) || ol.hasPrefix(nl) { return true }
        let n = min(old.count, new.count, 20)
        return n >= 8 && old.prefix(n) == new.prefix(n)
    }

    func send(pcm: Data) {
        guard let request, !didFinish, !pcm.isEmpty else { return }
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                            frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            guard let src = raw.baseAddress,
                  let dst = buffer.int16ChannelData?[0]
            else { return }
            memcpy(dst, src, pcm.count)
        }
        request.append(buffer)
    }

    func finish() {
        guard !didFinish else { return }
        finishRequested = true
        if !livePartial.isEmpty {
            committed = Self.merge(committed, livePartial)
            livePartial = ""
            publish()
        }
        request?.endAudio()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.doneTimer?.invalidate()
            self.doneTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                self?.complete()
            }
        }
    }

    func cancel() {
        didFinish = true
        doneTimer?.invalidate()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }

    private func complete() {
        guard !didFinish else { return }
        didFinish = true
        doneTimer?.invalidate()
        let text = bestText
        Log.write("Apple STT complete — \(text.isEmpty ? "EMPTY" : "\(text.count)ch")")
        task = nil
        request = nil
        DispatchQueue.main.async { [weak self] in self?.onComplete(text) }
    }

    /// macOS returns a terse system string; map the common case to something actionable.
    private static func friendlyMessage(for error: Error) -> String {
        let text = error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("siri") && lower.contains("dictation") {
            return Self.dictationDisabledMessage
        }
        if lower.contains("not authorized") || lower.contains("not authorised") {
            return "Speech Recognition permission denied — enable Quill in Privacy & Security ▸ Speech Recognition"
        }
        return text
    }

    static let dictationDisabledMessage =
        "Turn on Dictation in System Settings ▸ Keyboard ▸ Dictation (Apple Greek needs it)"

    static func openDictationSettings() {
        // macOS Sequoia / Tahoe Keyboard settings; fall back to classic Speech pane.
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation",
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard?Dictation",
            "x-apple.systempreferences:com.apple.preference.speech",
        ]
        for urlString in candidates {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) { return }
        }
    }

    /// True when the failure means Apple Speech cannot run until the user flips a system switch.
    static func isDictationDisabledError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("dictation") && (lower.contains("disabled") || lower.contains("turn on"))
    }

    /// English / tech terms Greek dictation often mangles — kept short for the API cap.
    private static let englishContextHints: [String] = [
        "hey", "Grok", "Grok Build", "Quill", "Mac", "macOS", "MacBook", "iPhone", "iPad",
        "iOS", "Swift", "Xcode", "GitHub", "Google", "WhatsApp", "email", "Slack", "Zoom",
        "Control", "Command", "Option", "Escape", "Terminal", "Finder", "Safari", "Chrome",
        "API", "JSON", "Python", "JavaScript", "TypeScript", "Docker", "OpenAI", "Claude",
        "Windows", "Linux", "Bluetooth", "Wi‑Fi", "USB", "PDF", "URL", "password", "login",
    ]
}
