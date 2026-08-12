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
    private var bestText = ""
    private var doneTimer: Timer?

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
        bestText = ""

        let localeId = language == "el" ? "el-GR" : language
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)),
              recognizer.isAvailable
        else {
            DispatchQueue.main.async { [weak self] in
                self?.onFailure("Apple speech recognition is not available for this language")
            }
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Bias common English words a Greek speaker inserts mid-sentence.
        // Without this, el-GR often writes them in Greek letters (κροκ, μακούς…).
        request.contextualStrings = Self.englishContextHints
        // On-device is faster, private, and usually better for Greek when installed.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            Log.write("Apple STT: on-device \(localeId)")
        } else {
            Log.write("Apple STT: network \(localeId)")
        }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, !self.didFinish else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // After endAudio Apple often emits an empty isFinal. Never let that
                // wipe a live transcript we already showed the user.
                if !text.isEmpty {
                    self.bestText = text
                    DispatchQueue.main.async { self.onText(text) }
                } else {
                    Log.write("Apple STT: ignoring empty \(result.isFinal ? "final" : "partial")")
                }
                if result.isFinal {
                    self.complete()
                    return
                }
            }

            if let error {
                let ns = error as NSError
                Log.write("Apple STT error: \(ns.domain) code=\(ns.code) — \(error.localizedDescription) bestText=\(self.bestText.count)ch")
                // 1110 "No speech detected", 216/203 cancel — all fine if we already have words.
                if !self.bestText.isEmpty {
                    self.complete()
                    return
                }
                DispatchQueue.main.async {
                    self.onFailure(Self.friendlyMessage(for: error))
                }
            }
        }

        DispatchQueue.main.async { [weak self] in self?.onReady() }
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
        request?.endAudio()
        // If the engine never fires isFinal, don't hang the UI.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.doneTimer?.invalidate()
            self.doneTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
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
