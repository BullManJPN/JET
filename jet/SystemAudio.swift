import Foundation
import ScreenCaptureKit
import Speech
import AVFoundation
import CoreMedia
import CoreGraphics

// システム音声(Web会議の相手の声など)の取り込み。ScreenCaptureKit の音声だけを使う
// 確認済み(S4a, macOS 27.2): 48kHz モノ Float32、960フレーム(20ms)ずつ届く。
// excludesCurrentProcessAudio は起動元(Terminal)配下の音も除外してしまうので、既定では除外しない
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let excludeSelf: Bool
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onStop: @Sendable (String) -> Void
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "jet.sck.audio")

    init(excludeSelf: Bool,
         onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         onStop: @escaping @Sendable (String) -> Void) {
        self.excludeSelf = excludeSelf
        self.onBuffer = onBuffer
        self.onStop = onStop
    }

    static func toPCM(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = sb.formatDescription, var asbd = fd.audioStreamBasicDescription else { return nil }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        pcm.frameLength = n
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: pcm.mutableAudioBufferList)
        return st == noErr ? pcm : nil
    }

    func start() async throws {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            throw AppError("画面とシステムオーディオの録音の許可がありません(システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 で Terminal を許可し、Terminal を再起動)")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AppError("ディスプレイが見つかりません") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = excludeSelf
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let pcm = SystemAudioCapture.toPCM(sb) else { return }
        onBuffer(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop("\(error)")
    }
}

/// 取り込んだバッファを、マイクと同じ受け口(保存・音量・変換・時計・SpeechAnalyzer への投入)へ渡す。
/// SCStream のキューから1本ずつ呼ばれるので、ロックなしで状態を持つ
final class SysFeeder: @unchecked Sendable {
    private let format: AVAudioFormat
    private let cont: AsyncStream<AnalyzerInput>.Continuation
    private let savePath: String?
    private let clock: LiveClock
    private var conv: AVAudioConverter?
    private var saver: AudioSaver?
    private var warned = false

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         savePath: String?, clock: LiveClock) {
        self.format = format
        self.cont = continuation
        self.savePath = savePath
        self.clock = clock
    }

    func handle(_ buf: AVAudioPCMBuffer) {
        if conv == nil {
            conv = AVAudioConverter(from: buf.format, to: format)
            if conv == nil {
                if !warned { warned = true; fputs("コンバーターを作れません: \(buf.format) → \(format)\n", stderr) }
                return
            }
            if let sp = savePath { saver = try? AudioSaver(path: sp, format: buf.format) }
        }
        saver?.write(buf)
        if let c = conv, let out = convertAudio(buf, using: c, to: format) {
            clock.markAudioStart()
            cont.yield(AnalyzerInput(buffer: out))
        }
    }

    func close() { saver?.close() }
}
