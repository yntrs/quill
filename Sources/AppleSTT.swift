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

        // Drop the previous request first. Leftover audio on a still-live task
        // is how a long sentence gets recognised a second time after a pause.
        if let oldRequest = request {
            request = nil
            oldRequest.endAudio()
        }
        if let oldTask = task {
            task = nil
            oldTask.cancel()
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = Self.mixedLanguageHints
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
                    let noSpeech = ns.code == 1110
                        || ns.localizedDescription.lowercased().contains("no speech")
                    if !self.bestText.isEmpty, !noSpeech {
                        self.complete()
                    } else {
                        if noSpeech, !self.bestText.isEmpty {
                            Log.write("Apple STT: ignoring \(self.bestText.count)ch after no-speech")
                        }
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
                // Restart on the next turn so we do not cancel this task from
                // inside its own callback (that re-enters the error path).
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.didFinish, !self.finishRequested else { return }
                    guard self.generation == gen, let recognizer = self.recognizer else { return }
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
        bestText = Self.collapseRepeated(bestText)
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
    /// that was producing "grok grok" → "grok grok grok grok". On longer
    /// sentences it restates with a slightly different opening, so exact
    /// prefix/suffix matching is not enough.
    private static func merge(_ committed: String, _ incoming: String) -> String {
        let a = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if alreadyHas(a, b) { return a }

        let aw = foldedTokens(a)
        let bw = foldedTokens(b)
        let rawB = tokens(b)

        let pref = commonPrefixCount(aw, bw)
        if pref == aw.count { return b }
        if pref == bw.count { return a }
        if pref >= 5 { return aw.count >= bw.count ? a : b }

        // Short revision: "Μπορώ να το διορθώσουμε" → "Μπορούμε να το διορθώσουμε".
        if isNearRevision(aw, bw) { return aw.count > bw.count ? a : b }

        // "Κι εσύ " + the sentence we already have (+ maybe a short new tail).
        if bw.count >= 6 {
            for skip in 1...3 where bw.count - skip >= 5 {
                let matched = commonPrefixCount(aw, Array(bw.dropFirst(skip)))
                guard matched >= 5 else { continue }
                let consumed = skip + matched
                guard consumed >= Int((Double(bw.count) * 0.65).rounded(.down)) else { continue }
                if consumed >= rawB.count { return a }
                let tail = rawB.dropFirst(consumed).joined(separator: " ")
                return tail.isEmpty ? a : join(a, tail)
            }
        }

        // Incoming restates a span already inside committed.
        let contained = longestPrefixContained(bw, in: aw, minLength: 8)
        if contained >= 8 {
            if contained >= Int((Double(bw.count) * 0.65).rounded(.down)) { return a }
            if contained < rawB.count {
                return join(a, rawB.dropFirst(contained).joined(separator: " "))
            }
            return a
        }

        // Short restated tail after Apple splits on a name/URL
        // ("…είμαι στο Grok.com" + "είμαι στο Grok.com και…").
        let overlap = longestSuffixPrefix(aw, bw)
        if overlap >= 3 {
            if overlap >= rawB.count { return a }
            return join(a, rawB.dropFirst(overlap).joined(separator: " "))
        }

        if aw.count >= 5, indexOf(aw, in: bw) != nil { return b }
        if bw.count >= 5, indexOf(bw, in: aw) != nil { return a }
        if b.hasPrefix(a) { return b }
        return join(a, b)
    }

    /// "hello world hello world" → "hello world"
    /// Also drops a later sentence that restates an earlier one — Apple's
    /// long-utterance path often emits A, then a near-copy of A.
    private static func collapseRepeated(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = tokens(trimmed)
        let folded = parts.map(Self.folded)
        if parts.count >= 2, parts.count % 2 == 0 {
            let half = parts.count / 2
            if Array(folded.prefix(half)) == Array(folded.suffix(half)) {
                return parts.prefix(half).joined(separator: " ")
            }
        }
        return collapseRepeatedPhrase(
            collapseRestatedSentences(
                collapseConsecutiveRepeats(trimmed)))
    }

    private static func alreadyHas(_ committed: String, _ incoming: String) -> Bool {
        let a = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || b.isEmpty { return false }
        if a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }
        let al = a.lowercased()
        let bl = b.lowercased()
        if al.hasSuffix(bl) { return true }
        let aw = foldedTokens(a)
        let bw = foldedTokens(b)
        guard !bw.isEmpty, aw.count >= bw.count else { return false }
        return Array(aw.suffix(bw.count)) == bw
    }

    /// Same utterance growing/revising vs a brand-new sentence after a pause.
    private static func isContinuation(old: String, new: String) -> Bool {
        if new.hasPrefix(old) || old.hasPrefix(new) { return true }
        let ol = old.lowercased(), nl = new.lowercased()
        if nl.hasPrefix(ol) || ol.hasPrefix(nl) { return true }
        let n = min(old.count, new.count, 20)
        if n >= 8, old.prefix(n) == new.prefix(n) { return true }

        let ow = foldedTokens(old)
        let nw = foldedTokens(new)
        if commonPrefixCount(ow, nw) >= 3 { return true }
        if isNearRevision(ow, nw) { return true }

        // On long phrases Apple revises the opening ("Και συνήθως…" →
        // "Κι εσύ και συνήθως…"). That is still the same hypothesis.
        if ow.count >= 5, nw.count >= 5 {
            for skipOld in 0...2 {
                for skipNew in 0...2 {
                    if commonPrefixCount(Array(ow.dropFirst(skipOld)),
                                         Array(nw.dropFirst(skipNew))) >= 4 {
                        return true
                    }
                }
            }
            let needed = max(5, Int((Double(ow.count) * 0.7).rounded(.down)))
            if orderedOverlap(ow, in: nw) >= needed { return true }
        }
        return false
    }

    // MARK: Word-level helpers

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func folded(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters)
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "el_GR"))
    }

    private static func foldedTokens(_ text: String) -> [String] {
        tokens(text).map(folded).filter { !$0.isEmpty }
    }

    private static func commonPrefixCount(_ a: [String], _ b: [String]) -> Int {
        var n = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            n += 1
        }
        return n
    }

    private static func indexOf(_ needle: [String], in hay: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        let last = hay.count - needle.count
        if last < 0 { return nil }
        for i in 0...last {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }

    private static func longestSuffixPrefix(_ a: [String], _ b: [String]) -> Int {
        let maxn = min(a.count, b.count)
        guard maxn >= 3 else { return 0 }
        for n in stride(from: maxn, through: 3, by: -1) {
            if Array(a.suffix(n)) == Array(b.prefix(n)) { return n }
        }
        return 0
    }

    /// Longest prefix of `needle` that appears as a contiguous span in `hay`.
    private static func longestPrefixContained(_ needle: [String], in hay: [String],
                                               minLength: Int) -> Int {
        let maxn = min(hay.count, needle.count)
        guard maxn >= minLength else { return 0 }
        for n in stride(from: maxn, through: minLength, by: -1) {
            if indexOf(Array(needle.prefix(n)), in: hay) != nil { return n }
        }
        return 0
    }

    private static func orderedOverlap(_ a: [String], in b: [String]) -> Int {
        var i = 0
        var hit = 0
        for word in a {
            if let found = b[i...].firstIndex(of: word) {
                hit += 1
                i = found + 1
            }
        }
        return hit
    }

    /// Same thought, one word inflected or re-guessed. 3 of 4 matching
    /// ("να το διορθώσουμε") is enough; two unrelated short sentences are not.
    private static func isNearRevision(_ a: [String], _ b: [String]) -> Bool {
        let short = a.count <= b.count ? a : b
        let long = a.count <= b.count ? b : a
        guard short.count >= 3, long.count <= short.count + 3 else { return false }
        let hit = orderedOverlap(short, in: long)
        return hit >= max(3, Int((Double(short.count) * 0.7).rounded(.down)))
    }

    private static func isRestatement(_ later: String, of earlier: String) -> Bool {
        let lw = foldedTokens(later)
        let ew = foldedTokens(earlier)
        if lw.count >= 4, ew.count >= 3, isNearRevision(lw, ew) { return true }
        guard lw.count >= 6 else { return false }
        if indexOf(lw, in: ew) != nil { return true }
        for skip in 0...3 {
            let body = Array(lw.dropFirst(skip))
            guard body.count >= 6 else { break }
            let contained = longestPrefixContained(body, in: ew, minLength: 6)
            if contained >= 6, contained >= Int((Double(body.count) * 0.65).rounded(.down)) {
                return true
            }
            let maxn = min(ew.count, body.count)
            if maxn >= 6 {
                for k in stride(from: maxn, through: 6, by: -1) {
                    if Array(ew.suffix(k)) == Array(body.prefix(k)),
                       k >= Int((Double(body.count) * 0.65).rounded(.down)) {
                        return true
                    }
                }
            }
        }
        let hit = orderedOverlap(lw, in: ew)
        return hit >= 6 && hit >= Int((Double(lw.count) * 0.75).rounded(.down))
    }

    /// "είμαι στο Grok.com, είμαι στο Grok.com, είμαι στο Grok.com" → one copy.
    /// Apple often re-emits the last few words when it splits on a name or URL.
    private static func collapseConsecutiveRepeats(_ text: String) -> String {
        var parts = tokens(text)
        var nw = parts.map(folded)
        var i = 0
        while i < nw.count {
            var didCollapse = false
            let maxN = min(8, (nw.count - i) / 2)
            if maxN >= 3 {
                for n in stride(from: maxN, through: 3, by: -1) {
                    let phrase = Array(nw[i..<(i + n)])
                    var j = i + n
                    var runs = 1
                    while j + n <= nw.count, Array(nw[j..<(j + n)]) == phrase {
                        runs += 1
                        j += n
                    }
                    guard runs >= 2 else { continue }
                    // Keep the last copy — it usually has the real punctuation.
                    let kept = Array(parts[(j - n)..<j])
                    parts = Array(parts[..<i]) + kept + Array(parts[j...])
                    nw = parts.map(folded)
                    didCollapse = true
                    break
                }
            }
            if !didCollapse { i += 1 }
        }
        return parts.joined(separator: " ")
    }

    private static func collapseRestatedSentences(_ text: String) -> String {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substr, _, _, _ in
            guard let s = substr?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
            else { return }
            sentences.append(s)
        }
        guard sentences.count >= 2 else { return text }
        var kept: [String] = []
        var earlier = ""
        for sentence in sentences {
            if !kept.isEmpty, isRestatement(sentence, of: earlier) { continue }
            if let last = kept.last, isRestatement(sentence, of: last) { continue }
            kept.append(sentence)
            earlier = earlier.isEmpty ? sentence : join(earlier, sentence)
        }
        return kept.joined(separator: " ")
    }

    private static func collapseRepeatedPhrase(_ text: String) -> String {
        let parts = tokens(text)
        let nw = parts.map(folded)
        let minlen = 8
        guard nw.count >= minlen * 2 else { return text }
        var i = 0
        while i <= nw.count - minlen {
            var found: (length: Int, at: Int)?
            let maxL = min(40, nw.count - i)
            if maxL >= minlen {
                for length in stride(from: maxL, through: minlen, by: -1) {
                    let phrase = Array(nw[i..<(i + length)])
                    let searchStart = i + length
                    let searchEnd = nw.count - length
                    if searchStart <= searchEnd {
                        for j in searchStart...searchEnd {
                            if Array(nw[j..<(j + length)]) == phrase {
                                found = (length, j)
                                break
                            }
                        }
                    }
                    if found != nil { break }
                }
            }
            if let found {
                let length = found.length
                let j = found.at
                let gap = j - (i + length)
                let dropFrom = (gap > 0 && gap <= 3) ? (i + length) : j
                var tailStart = j + length
                if tailStart < nw.count, dropFrom > 0 {
                    let tail = Array(nw[tailStart...])
                    let kept = Array(nw[..<dropFrom])
                    let m = min(tail.count, kept.count, 12)
                    var overlap = 0
                    if m >= 3 {
                        for k in stride(from: m, through: 3, by: -1) {
                            if Array(kept.suffix(k)) == Array(tail.prefix(k)) {
                                overlap = k
                                break
                            }
                        }
                    }
                    if overlap >= 3, overlap >= Int((Double(min(tail.count, 8)) * 0.6).rounded(.down)) {
                        tailStart += overlap
                    }
                }
                let rebuilt = (Array(parts[..<dropFrom]) + Array(parts[tailStart...]))
                    .joined(separator: " ")
                return collapseRepeatedPhrase(rebuilt)
            }
            i += 1
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let raw = bestText
        let text = Self.collapseRepeated(raw)
        if text != raw, text.count + 16 < raw.count {
            Log.write("Apple STT: dropped restated words \(raw.count)ch → \(text.count)ch")
        }
        bestText = text
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

    /// English words dropped into Greek speech — Apple's el-GR model otherwise
    /// writes them in Greek letters. Cap is roughly 100 strings.
    private static var mixedLanguageHints: [String] {
        var hints = englishContextHints
        var seen = Set(hints.map { $0.lowercased() })
        let history = UserDefaults.standard.stringArray(forKey: "history") ?? []
        for line in history.prefix(10) {
            for raw in line.split(whereSeparator: { $0.isWhitespace }) {
                let word = String(raw).trimmingCharacters(in: .punctuationCharacters)
                guard word.count >= 2, word.count <= 24 else { continue }
                let letters = word.unicodeScalars
                guard letters.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII })
                else { continue }
                let key = word.lowercased()
                guard seen.insert(key).inserted else { continue }
                hints.append(word)
            }
        }
        if hints.count > 100 { hints = Array(hints.prefix(100)) }
        return hints
    }

    private static let englishContextHints: [String] = [
        "hey", "Grok", "Grok Build", "Quill", "Mac", "macOS", "MacBook", "iPhone", "iPad",
        "iOS", "Swift", "Xcode", "GitHub", "Google", "WhatsApp", "email", "Slack", "Zoom",
        "Control", "Command", "Option", "Escape", "Terminal", "Finder", "Safari", "Chrome",
        "API", "JSON", "Python", "JavaScript", "TypeScript", "Docker", "OpenAI", "Claude",
        "Windows", "Linux", "Bluetooth", "Wi‑Fi", "USB", "PDF", "URL", "password", "login",
        "you", "true", "false", "yes", "no", "please", "thanks", "update", "translate",
        "trigger", "timeout", "log", "build", "fix", "bug", "commit", "push", "pull",
        "English", "Greek", "post", "chat", "message", "okay", "ok", "wait",
    ]
}
