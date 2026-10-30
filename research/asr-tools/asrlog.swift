// asrlog.swift — SpeechAnalyzer の途中結果/確定結果を時刻つきで記録する検証ツール
//
// 使い方:
//   ./asrlog --file samples/tts1.aiff            音声ファイルを実時間で流して記録
//   ./asrlog --mic --seconds 90                  マイクから90秒記録
//   ./asrlog --mic --seconds 90 --save-audio     マイクの音声も samples/mic-<日時>.wav に保存
//   ./asrlog --file x.aiff --engine dictation    DictationTranscriber で認識(既定は speech = SpeechTranscriber)
//   ./asrlog --file x.aiff --engine dictation --terms asr/terms.txt   語彙ヒント(contextualStrings)つき
// 出力: logs/asr-YYYYmmdd-HHMMSS.jsonl (1行1イベント)
//
// lag = 「そのイベントが画面に届いた時刻」−「その音声区間の終わりの時刻」(秒)
import Foundation
import Speech
import AVFoundation
import CoreMedia

struct Options {
    var file: String? = nil
    var mic = false
    var locale = "en-US"
    var seconds: Double = 60
    var tail: Double = 4        // ファイル末尾に足す無音(秒)。確定のきっかけ観察用
    var fast = false            // .fastResults を有効にする
    var prepare = false         // prepareToAnalyze で予熱する
    var preset = false          // .timeIndexedProgressiveTranscription プリセット(volatile+fast+時間情報)を使う
    var chunkMs: Double = 100   // ファイル投入時の1回あたりの音声長(ミリ秒)
    var tag = ""                // ログ名に付ける目印
    var engine = "speech"       // speech = SpeechTranscriber / dictation = DictationTranscriber
    var terms: String? = nil    // 語彙ヒントのファイル(1行1語)。dictation のみ有効
    var saveAudio = false       // マイク音声を samples/ に保存
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--file": o.file = it.next()
        case "--mic": o.mic = true
        case "--locale": if let v = it.next() { o.locale = v }
        case "--seconds": if let v = it.next(), let d = Double(v) { o.seconds = d }
        case "--tail": if let v = it.next(), let d = Double(v) { o.tail = d }
        case "--fast": o.fast = true
        case "--prepare": o.prepare = true
        case "--preset": o.preset = true
        case "--chunk-ms": if let v = it.next(), let d = Double(v) { o.chunkMs = d }
        case "--tag": if let v = it.next() { o.tag = v }
        case "--engine": if let v = it.next() { o.engine = v }
        case "--terms": o.terms = it.next()
        case "--save-audio": o.saveAudio = true
        default: fputs("不明な引数: \(a)\n", stderr)
        }
    }
    return o
}

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

let t0 = ProcessInfo.processInfo.systemUptime
func now() -> Double { ProcessInfo.processInfo.systemUptime - t0 }

final class AudioSaver: @unchecked Sendable {
    private var file: AVAudioFile?
    private let lock = NSLock()
    let path: String
    init(path: String, format: AVAudioFormat) throws {
        self.path = path
        file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
    }
    func write(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        try? file?.write(from: buf)
    }
    func close() { lock.lock(); file = nil; lock.unlock() }
}

final class Recorder: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    var audioT0: Double? = nil   // 最初の音声バッファを投入した時刻
    private var fedSec: Double = 0   // ここまでに投入した音声の長さ(秒)
    func addFed(_ s: Double) { lock.lock(); fedSec += s; lock.unlock() }
    func fed() -> Double { lock.lock(); defer { lock.unlock() }; return fedSec }
    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }
    func markAudioStart() {
        lock.lock(); defer { lock.unlock() }
        if audioT0 == nil { audioT0 = now() }
    }
    func write(_ obj: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) {
            handle.write(d); handle.write(Data("\n".utf8))
        }
    }
}

func convert(_ buf: AVAudioPCMBuffer, using conv: AVAudioConverter, to fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
    let ratio = fmt.sampleRate / buf.format.sampleRate
    let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
    var supplied = false
    var err: NSError?
    let status = conv.convert(to: out, error: &err) { _, outStatus in
        if supplied { outStatus.pointee = .noDataNow; return nil }
        supplied = true
        outStatus.pointee = .haveData
        return buf
    }
    if status == .error { fputs("変換エラー: \(String(describing: err))\n", stderr); return nil }
    return out
}

@main
struct ASRLog {
    static func main() async {
        let opt = parseArgs()
        do { try await run(opt) } catch {
            fputs("エラー: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run(_ opt: Options) async throws {
        guard opt.file != nil || opt.mic else {
            throw AppError("--file <音声ファイル> か --mic を指定してください")
        }

        // 1. ロケールと音声認識モデル
        let wanted = opt.locale
        let module: any SpeechModule
        var speechT: SpeechTranscriber? = nil
        var dictT: DictationTranscriber? = nil
        if opt.engine == "dictation" {
            guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: wanted)) else {
                throw AppError("DictationTranscriber はロケール \(wanted) に未対応です")
            }
            let t = DictationTranscriber(locale: loc, contentHints: [], transcriptionOptions: [],
                                         reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            dictT = t; module = t
        } else {
            let supported = await SpeechTranscriber.supportedLocales
            guard let locale = supported.first(where: {
                $0.identifier.replacingOccurrences(of: "_", with: "-") == wanted
            }) else {
                throw AppError("ロケール \(wanted) は未対応です。対応: \(supported.map { $0.identifier }.sorted().prefix(30))")
            }
            let t: SpeechTranscriber
            if opt.preset {
                t = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            } else {
                var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
                if opt.fast { reporting.insert(.fastResults) }
                t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                      reportingOptions: reporting, attributeOptions: [.audioTimeRange])
            }
            speechT = t; module = t
        }

        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            print("音声認識モデルをダウンロード中…")
            try await req.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        var termsCount = 0
        if let tp = opt.terms {
            let list = try String(contentsOfFile: tp, encoding: .utf8)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            termsCount = list.count
            if opt.engine == "dictation" {
                let ctx = AnalysisContext()
                ctx.contextualStrings[AnalysisContext.ContextualStringsTag("terms")] = list
                try await analyzer.setContext(ctx)
                print("語彙ヒント \(list.count) 語を設定しました")
            } else {
                print("注意: SpeechTranscriber は語彙ヒントを使えないため --terms は無視します")
                termsCount = 0
            }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AppError("互換する音声フォーマットが取得できません")
        }
        print("音声フォーマット: \(format)")
        print("設定: preset=\(opt.preset) fast=\(opt.fast) prepare=\(opt.prepare) chunk=\(Int(opt.chunkMs))ms")
        if opt.prepare { try await analyzer.prepareToAnalyze(in: format) }

        // 2. 記録先
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let logPath = "logs/asr-\(df.string(from: Date()))\(opt.tag.isEmpty ? "" : "-" + opt.tag).jsonl"
        let rec = try Recorder(path: logPath)
        rec.write(["kind": "meta", "locale": wanted, "source": opt.file ?? "mic",
                   "format": "\(format)", "preset": opt.preset, "fast": opt.fast,
                   "prepare": opt.prepare, "chunk_ms": opt.chunkMs,
                   "engine": opt.engine, "terms_count": termsCount])

        // 3. 結果の受信
        let handle: @Sendable (Bool, AttributedString, CMTimeRange) -> Void = { isFinal, attr, r in
            let w = now()
            let text = String(attr.characters)
            let aStart = r.start.seconds
            let aEnd = (r.start + r.duration).seconds
            let base = rec.audioT0 ?? 0
            let lag = w - base - aEnd
            let fedNow = rec.fed()
            let lagFed = fedNow - aEnd
            var wordEnd = 0.0
            for run in attr.runs {
                if let tr = run.audioTimeRange {
                    wordEnd = max(wordEnd, (tr.start + tr.duration).seconds)
                }
            }
            let wordLagFed = fedNow - wordEnd
            rec.write(["kind": isFinal ? "final" : "volatile",
                       "wall": (w * 1000).rounded() / 1000,
                       "audio_start": (aStart * 1000).rounded() / 1000,
                       "audio_end": (aEnd * 1000).rounded() / 1000,
                       "lag": (lag * 1000).rounded() / 1000,
                       "fed": (fedNow * 1000).rounded() / 1000,
                       "lag_fed": (lagFed * 1000).rounded() / 1000,
                       "word_end": (wordEnd * 1000).rounded() / 1000,
                       "word_lag_fed": (wordLagFed * 1000).rounded() / 1000,
                       "text": text])
            print(String(format: "%@ %6.2fs wordLag %5.2f | %@",
                         isFinal ? "FINAL   " : "volatile", w, wordLagFed, text))
        }
        let resultsTask = Task {
            if let t = speechT {
                for try await result in t.results { handle(result.isFinal, result.text, result.range) }
            } else if let t = dictT {
                for try await result in t.results { handle(result.isFinal, result.text, result.range) }
            }
        }

        // 4. 音声の投入
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)

        if let path = opt.file {
            try await feedFile(path: path, format: format, tail: opt.tail, chunkMs: opt.chunkMs, rec: rec, continuation: continuation)
        } else {
            try await feedMic(seconds: opt.seconds, format: format, rec: rec, continuation: continuation,
                              savePath: opt.saveAudio ? "samples/mic-\(df.string(from: Date()))\(opt.tag.isEmpty ? "" : "-" + opt.tag).wav" : nil)
        }

        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try await resultsTask.value
        print("\n記録: \(logPath)")
        print("集計: python3 asr/analyze.py \(logPath)")
    }

    static func feedFile(path: String, format: AVAudioFormat, tail: Double, chunkMs: Double, rec: Recorder,
                         continuation: AsyncStream<AnalyzerInput>.Continuation) async throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let src = file.processingFormat
        guard let conv = AVAudioConverter(from: src, to: format) else {
            throw AppError("コンバーターを作れません: \(src) → \(format)")
        }
        let chunk = AVAudioFrameCount(src.sampleRate * chunkMs / 1000.0)
        var sent: Double = 0                 // 投入した音声の累計(秒)
        var startT: Double? = nil
        func pace() async throws {           // 累計音声長に合わせて絶対時刻で待つ(ずれを溜めない)
            let st = startT ?? now()
            startT = st
            let delay = st + sent - now()
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        }
        print("ファイル再生開始(実時間): \(path)  長さ \(String(format: "%.1f", Double(file.length) / src.sampleRate)) 秒")
        func push(_ buf: AVAudioPCMBuffer) {
            if let out = convert(buf, using: conv, to: format) {
                rec.markAudioStart()
                continuation.yield(AnalyzerInput(buffer: out))
                rec.addFed(Double(buf.frameLength) / src.sampleRate)
            }
        }
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            push(buf)
            sent += Double(buf.frameLength) / src.sampleRate
            try await pace()
        }
        // 末尾に無音を足して、無音が確定の引き金になるかを観察する
        var remain = tail
        while remain > 0 {
            guard let z = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunk) else { break }
            z.frameLength = chunk
            if let ch = z.floatChannelData {
                for c in 0..<Int(src.channelCount) { memset(ch[c], 0, Int(chunk) * MemoryLayout<Float>.size) }
            }
            push(z)
            sent += Double(chunk) / src.sampleRate
            try await pace()
            remain -= Double(chunk) / src.sampleRate
        }
    }

    static func feedMic(seconds: Double, format: AVAudioFormat, rec: Recorder,
                        continuation: AsyncStream<AnalyzerInput>.Continuation, savePath: String?) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AppError("マイクの許可がありません(システム設定 > プライバシーとセキュリティ > マイク)") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inFmt, to: format) else {
            throw AppError("コンバーターを作れません: \(inFmt) → \(format)")
        }
        var saver: AudioSaver? = nil
        if let sp = savePath { saver = try AudioSaver(path: sp, format: inFmt); print("音声を保存します: \(sp)") }
        let saverRef = saver
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { buf, _ in
            saverRef?.write(buf)
            if let out = convert(buf, using: conv, to: format) {
                rec.markAudioStart()
                continuation.yield(AnalyzerInput(buffer: out))
                rec.addFed(Double(buf.frameLength) / inFmt.sampleRate)
            }
        }
        engine.prepare()
        try engine.start()
        print("マイク録音中 \(Int(seconds)) 秒…(話してください / 動画を流してください)")
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        engine.stop()
        input.removeTap(onBus: 0)
        saver?.close()
    }
}
