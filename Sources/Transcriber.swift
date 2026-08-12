import Foundation

/// Shared surface for Grok STT and Apple Speech so the app can swap engines.
protocol StreamingTranscriber: AnyObject {
    var onText: (String) -> Void { get set }
    var onReady: () -> Void { get set }
    var onComplete: (String) -> Void { get set }
    var onFailure: (String) -> Void { get set }

    func send(pcm: Data)
    func finish()
    func cancel()
}
