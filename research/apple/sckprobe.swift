import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics

final class Probe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private(set) var buffers = 0
    private(set) var frames = 0
    private(set) var fmtDesc = ""
    private(set) var peak: Float = 0
    private var arrivals: [Double] = []
    private var sizes: [Int] = []
    private(set) var firstArrival: Double? = nil
    private(set) var stopError: String? = nil
    let outPath: String

    init(outPath: String) { self.outPath = outPath }

    static func toPCM(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = sb.formatDescription, var asbd = fd.audioStreamBasicDescription else { return nil }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        pcm.frameLength = n
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: pcm.mutableAudioBufferList)
        return st == noErr ? pcm : nil
    }

    private(set) var altPeak: Float = 0
    private(set) var altStatus: OSStatus = 0
    private(set) var altBytes = 0
    private(set) var altNonZero = 0
    private(set) var screenFrames = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { lock.lock(); screenFrames += 1; lock.unlock(); return }
        guard type == .audio, sb.isValid else { return }
        var abl = AudioBufferList()
        var bb: CMBlockBuffer?
        let ast = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &bb)
        lock.lock()
        altStatus = ast
        if ast == noErr, let d = abl.mBuffers.mData {
            let n = Int(abl.mBuffers.mDataByteSize) / 4
            altBytes += Int(abl.mBuffers.mDataByteSize)
            let f = d.assumingMemoryBound(to: Float.self)
            for i in 0..<n { let v = abs(f[i]); altPeak = max(altPeak, v); if v > 0 { altNonZero += 1 } }
        }
        lock.unlock()
        guard let pcm = Probe.toPCM(sb) else { return }
        let t = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if file == nil {
            fmtDesc = "\(pcm.format)"
            firstArrival = t
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            file = try? AVAudioFile(forWriting: URL(fileURLWithPath: outPath), settings: pcm.format.settings)
        }
        try? file?.write(from: pcm)
        buffers += 1
        frames += Int(pcm.frameLength)
        arrivals.append(t)
        sizes.append(Int(pcm.frameLength))
        if let ch = pcm.floatChannelData {
            for c in 0..<Int(pcm.format.channelCount) {
                let p = ch[c]
                for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(p[i])); lapPeak = max(lapPeak, abs(p[i])) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); stopError = "\(error)"; lock.unlock()
    }

    private var lapPeak: Float = 0
    func lap() -> Float { lock.lock(); defer { lock.unlock() }; let v = lapPeak; lapPeak = 0; return v }

    func close() { lock.lock(); file = nil; lock.unlock() }

    func report(rate: Double) -> String {
        lock.lock(); defer { lock.unlock() }
        var s = "バッファ数: \(buffers)\nフレーム合計: \(frames)"
        if rate > 0 { s += "(\(String(format: "%.2f", Double(frames) / rate)) 秒分)" }
        s += "\n形式: \(fmtDesc)"
        if !sizes.isEmpty {
            let sorted = sizes.sorted()
            s += "\n1バッファのフレーム数: 中央値 \(sorted[sorted.count / 2]) / 最大 \(sorted.last!)"
        }
        if arrivals.count > 1 {
            let gaps = zip(arrivals.dropFirst(), arrivals).map { $0 - $1 }.sorted()
            s += String(format: "\n到着間隔: 中央値 %.0fms / p90 %.0fms / 最大 %.0fms",
                        gaps[gaps.count / 2] * 1000, gaps[Int(Double(gaps.count) * 0.9)] * 1000, gaps.last! * 1000)
        }
        let db = peak > 0 ? 20 * log10(Double(peak)) : -Double.infinity
        s += String(format: "\n最大振幅: %.1f dBFS", db)
        let adb = altPeak > 0 ? 20 * log10(Double(altPeak)) : -Double.infinity
        s += String(format: "\n別の取り出し方: status %d / %d バイト / 非ゼロ %d 個 / 最大 %.1f dBFS", altStatus, altBytes, altNonZero, adb)
        s += "\n映像フレーム受信: \(screenFrames)"
        if peak == 0 { s += "(無音。音が鳴っていないか、許可が足りない可能性)" }
        if let e = stopError { s += "\nストリーム停止エラー: \(e)" }
        return s
    }
}

@main
struct SCKProbe {
    static func main() async {
        var seconds = 5.0
        var out = "samples/sys-probe.wav"
        var withScreen = false
        var includeSelf = false
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let a = args.removeFirst()
            if a == "--seconds", !args.isEmpty, let d = Double(args.removeFirst()) { seconds = d }
            else if a == "--out", !args.isEmpty { out = args.removeFirst() }
            else if a == "--screen" { withScreen = true }
            else if a == "--include-self" { includeSelf = true }
        }
        do {
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
                print("画面とシステムオーディオの録音の許可がありません。")
                print("システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 で Terminal を許可し、Terminal を再起動してください。")
                exit(1)
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { print("ディスプレイが見つかりません"); exit(1) }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = !includeSelf
            cfg.sampleRate = 48000
            cfg.channelCount = 1
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let probe = Probe(outPath: out)
            let stream = SCStream(filter: filter, configuration: cfg, delegate: probe)
            try stream.addStreamOutput(probe, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sck.audio"))
            if withScreen { try stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sck.screen")) }
            print("許可(preflight): \(CGPreflightScreenCaptureAccess()) / 映像出力も登録: \(withScreen) / 自プロセス音を除外: \(!includeSelf)")
            let t0 = ProcessInfo.processInfo.systemUptime
            try await stream.startCapture()
            let started = ProcessInfo.processInfo.systemUptime
            print("取り込み中 \(Int(seconds)) 秒…(開始に \(String(format: "%.0f", (started - t0) * 1000))ms)")
            for sec in 1...max(1, Int(seconds)) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let v = probe.lap()
                let db = v > 0 ? 20 * log10(Double(v)) : -Double.infinity
                print(String(format: "  %2d秒: %.1f dBFS", sec, db))
            }
            try await stream.stopCapture()
            probe.close()
            if let fa = probe.firstArrival {
                print(String(format: "startCapture 完了から最初のバッファまで: %.0fms", (fa - started) * 1000))
            }
            print(probe.report(rate: 48000))
            print("保存: \(out)")
        } catch {
            print("エラー: \(error)")
            exit(1)
        }
    }
}
