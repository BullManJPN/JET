import Foundation
import Speech
import AVFoundation
import CoreMedia

// マイク / 音声ファイル → SpeechAnalyzer → Engine → Pipeline。asr/asrlog.swift の入力部分を移植
// 認識結果は asrlog と同じ形式(logs/asr-<日時>-live.jsonl)で保存するので、後で --replay で再現できる(app モードは保存しない)

enum LiveIn: Sendable {
    case volatile(String, Double)
    case final(String, Double)
    case tick(Double)
}

/// 最初の音声バッファを0秒とする時計(asr/asrlog.swift と同じ基準。認識結果の audio_end とほぼ揃う)
final class LiveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t0: Double? = nil

    func markAudioStart() {
        lock.lock(); defer { lock.unlock() }
        if t0 == nil { t0 = ProcessInfo.processInfo.systemUptime }
    }

    func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let t = t0 else { return 0 }
        return ProcessInfo.processInfo.systemUptime - t
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
}

final class AsrLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?

    /// path が nil ならファイルには書かない(app モード)
    init(path: String?) throws {
        guard let path = path else { handle = nil; return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ o: [String: Any]) {
        guard let h = handle else { return }
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) else { return }
        lock.lock(); defer { lock.unlock() }
        h.write(d)
        h.write(Data("\n".utf8))
    }
}

final class AudioSaver: @unchecked Sendable {
    private var file: AVAudioFile?
    private let lock = NSLock()

    init(path: String, format: AVAudioFormat) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
    }

    func write(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        try? file?.write(from: buf)
    }

    func close() { lock.lock(); file = nil; lock.unlock() }
}

func convertAudio(_ buf: AVAudioPCMBuffer, using conv: AVAudioConverter, to fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
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

enum Live {
    static func up() -> Double { ProcessInfo.processInfo.systemUptime }

    static func run(file: String?, mic: Bool, system: Bool = false, excludeSelf: Bool = false, play: String? = nil,
                    seconds: Double, saveAudio: Bool,
                    conf: JetConfig, cor: Corrector,
                    sink: EventSink, draft: DraftTranslator,
                    clock: LiveClock = LiveClock(), stopFlag external: StopFlag? = nil) async throws {
        // 停止フラグを外から渡されたら(メニューバー)、Ctrl-C は奪わない。渡されなければ従来どおり Ctrl-C で止める
        let stop = external ?? StopFlag()
        var sigSrc: DispatchSourceSignal? = nil
        if external == nil {
            signal(SIGINT, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            s.setEventHandler { stop.set() }
            s.resume()
            sigSrc = s
        }
        defer { sigSrc?.cancel() }

        // 1. 音声認識(SpeechTranscriber)
        let wanted = conf.asrLocale
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = supported.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-") == wanted }) else {
            throw AppError("ロケール \(wanted) は未対応です")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let module: any SpeechModule = transcriber
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            print("音声認識モデルをダウンロード中…")
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AppError("互換する音声フォーマットが取得できません")
        }
        if conf.asrPrepare { try await analyzer.prepareToAnalyze(in: format) }

        // 2. 記録と各部品
        let now: @Sendable () -> Double = { clock.now() }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let ts = df.string(from: Date())
        let name = "\(ts)-live"
        let asrLog = try AsrLog(path: conf.keepLogs ? "\(conf.eventsDir)/asr-\(name).jsonl" : nil)
        asrLog.write(["kind": "meta", "locale": wanted, "source": file ?? (system ? "system" : "mic"), "format": "\(format)",
                      "preset": true, "prepare": conf.asrPrepare])
        // 開始の印(流れ型は区切りの行を出す)。照合(parity)は知らない kind を無視するので影響なし
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        let srcName = file != nil ? "ファイル" : (system ? "システム音声" : "マイク")
        sink.emit(["kind": "session", "t": 0.0, "file": name, "source": file ?? (system ? "system" : "mic"),
                   "label": "― \(hm.string(from: Date())) 開始(\(srcName))―"])
        let engine = Engine(cfg: conf.cfg, cor: cor, file: name)
        let pipe = Pipeline(conf: conf, sink: sink, file: name, now: now, draft: draft)

        // Engine と Pipeline は1つのタスクだけが触る(認識結果と tick は AsyncStream で順番に渡す)
        let (inStream, inCont) = AsyncStream.makeStream(of: LiveIn.self)
        let engineTask = Task {
            for await item in inStream {
                switch item {
                case .volatile(let t, let w): pipe.handle(engine.volatile(t, wall: w))
                case .final(let t, let w): pipe.handle(engine.finalize(t, wall: w))
                case .tick(let n): pipe.handle(engine.tick(n))
                }
            }
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                inCont.yield(.tick(now()))
            }
        }
        let resultsTask = Task {
            for try await result in transcriber.results {
                let w = now()
                let text = String(result.text.characters)
                let r = result.range
                asrLog.write(["kind": result.isFinal ? "final" : "volatile", "wall": (w * 1000).rounded() / 1000,
                              "audio_start": (r.start.seconds * 1000).rounded() / 1000,
                              "audio_end": ((r.start + r.duration).seconds * 1000).rounded() / 1000,
                              "text": text])
                inCont.yield(result.isFinal ? .final(text, w) : .volatile(text, w))
            }
        }

        // 3. 音声の投入
        let (audioStream, audioCont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let savePath = saveAudio ? JetPaths.writable("samples/\(system ? "sys" : "mic")-\(name).wav") : nil
        do {
            try await analyzer.start(inputSequence: audioStream)
            if let path = file {
                try await feedFile(path: path, format: format, tail: 4, continuation: audioCont, stop: stop, clock: clock)
            } else if system {
                try await feedSystem(seconds: seconds, format: format, continuation: audioCont, savePath: savePath, stop: stop,
                                     clock: clock, excludeSelf: excludeSelf, play: play)
            } else if mic {
                try await feedMic(seconds: seconds, format: format, continuation: audioCont, savePath: savePath, stop: stop, clock: clock)
            }
        } catch {
            // 途中で失敗(マイクの許可なし・取り込み開始の失敗など)。メニューバーではアプリが続くので、
            // 認識・tick・結果待ちのタスクを残さず片付けてから投げる(前の回の残りが次の回に混ざらないように)
            audioCont.finish()
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            ticker.cancel()
            inCont.finish()
            await engineTask.value
            await pipe.drain()
            throw error
        }

        // 4. 終了処理
        print("\n終了処理中…")
        audioCont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try await resultsTask.value
        ticker.cancel()
        inCont.finish()
        await engineTask.value
        await pipe.drain()
        if conf.keepLogs { print("認識ログ: \(conf.eventsDir)/asr-\(name).jsonl") }
        if let sp = savePath { print("音声: \(sp)") }
    }

    static func feedSystem(seconds: Double, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
                           savePath: String?, stop: StopFlag, clock: LiveClock,
                           excludeSelf: Bool, play: String?) async throws {
        let feeder = SysFeeder(format: format, continuation: continuation, savePath: savePath, clock: clock)
        let cap = SystemAudioCapture(excludeSelf: excludeSelf,
                                     onBuffer: { feeder.handle($0) },
                                     onStop: { msg in fputs("\nシステム音声の取り込みが止まりました: \(msg)\n", stderr); stop.set() })
        try await cap.start()
        print("システム音声取り込み中 \(seconds > 0 ? "\(Int(seconds)) 秒" : "(Ctrl-C で終了)")…")
        var player: Process? = nil
        if let wav = play {
            let pr = Process()
            pr.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            pr.arguments = [wav]
            try pr.run()
            player = pr
            print("再生: \(wav)")
        }
        let end = seconds > 0 ? up() + seconds : Double.infinity
        while up() < end && !stop.get() {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        player?.terminate()
        await cap.stop()
        feeder.close()
    }

    static func feedMic(seconds: Double, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
                        savePath: String?, stop: StopFlag, clock: LiveClock) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AppError("マイクの許可がありません(システム設定 > プライバシーとセキュリティ > マイク)") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inFmt, to: format) else {
            throw AppError("コンバーターを作れません: \(inFmt) → \(format)")
        }
        var saver: AudioSaver? = nil
        if let sp = savePath { saver = try AudioSaver(path: sp, format: inFmt) }
        let saverRef = saver
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { buf, _ in
            saverRef?.write(buf)
            if let out = convertAudio(buf, using: conv, to: format) {
                clock.markAudioStart()
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }
        engine.prepare()
        try engine.start()
        print("マイク録音中 \(seconds > 0 ? "\(Int(seconds)) 秒" : "(Ctrl-C で終了)")…(話してください)")
        let end = seconds > 0 ? up() + seconds : Double.infinity
        while up() < end && !stop.get() {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        engine.stop()
        input.removeTap(onBus: 0)
        saver?.close()
    }

    static func feedFile(path: String, format: AVAudioFormat, tail: Double,
                         continuation: AsyncStream<AnalyzerInput>.Continuation, stop: StopFlag, clock: LiveClock) async throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let src = file.processingFormat
        guard let conv = AVAudioConverter(from: src, to: format) else {
            throw AppError("コンバーターを作れません: \(src) → \(format)")
        }
        let chunk = AVAudioFrameCount(src.sampleRate * 0.1)
        var sent: Double = 0
        let start = up()
        func pace() async throws {
            let delay = start + sent - up()
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        }
        func push(_ buf: AVAudioPCMBuffer) {
            if let out = convertAudio(buf, using: conv, to: format) {
                clock.markAudioStart()
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }
        print("ファイル再生開始(実時間): \(path)  長さ \(String(format: "%.1f", Double(file.length) / src.sampleRate)) 秒")
        while file.framePosition < file.length && !stop.get() {
            guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            push(buf)
            sent += Double(buf.frameLength) / src.sampleRate
            try await pace()
        }
        // 末尾に無音を足して、最後の区間の確定を促す
        var remain = tail
        while remain > 0 && !stop.get() {
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
}
