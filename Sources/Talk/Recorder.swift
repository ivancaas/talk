import AVFoundation

/// Records the default input to 16 kHz mono Float32. The audio engine exists only while recording.
final class Recorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Called on the main queue with a 0...1 mic level while recording.
    var onLevel: ((Float) -> Void)?
    /// Called on the main queue when the input device changes or disappears mid-recording (headset unplugged,
    /// AirPods switched away). The engine has stopped by then; call `stop()` to collect what was recorded.
    var onInterrupted: (() -> Void)?
    private var configObserver: NSObjectProtocol?

    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "talk", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"]) }
        guard let converter = AVAudioConverter(from: format, to: Self.target) else {
            throw NSError(domain: "talk", code: 2, userInfo: [NSLocalizedDescriptionKey: "unsupported microphone format"])
        }
        // The tap (audio thread) gets its own reference; `self.converter` is only touched on main after the tap is gone.
        self.converter = converter
        lock.lock(); samples.removeAll(keepingCapacity: false); lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer, with: converter)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.onInterrupted?()
        }
    }

    /// Stops and releases the engine (mic indicator goes off), returns the recording.
    func stop() -> [Float] {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        // The resampler holds back up to ~50 ms; drain it so the last syllable isn't cut.
        if let converter, let tail = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: 4096) {
            var error: NSError?
            converter.convert(to: tail, error: &error) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if error == nil, let ch = tail.floatChannelData, tail.frameLength > 0 {
                lock.lock(); samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(tail.frameLength))); lock.unlock()
            }
        }
        converter = nil
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    private func append(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) {
        let out = Self.convert(buffer, with: converter)
        lock.lock(); samples.append(contentsOf: out); lock.unlock()
        guard let onLevel, !out.isEmpty else { return }
        var sum: Float = 0
        for x in out { sum += x * x }
        let db = 20 * log10(max(sqrt(sum / Float(out.count)), 1e-6))
        let level = min(1, max(0, (db + 50) / 40))  // -50 dB → 0, -10 dB → 1
        DispatchQueue.main.async { onLevel(level) }
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// For the CLI self-test: any audio file → 16 kHz mono samples.
    static func load(file url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buf)
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        return convert(buf, with: conv)
    }
}
