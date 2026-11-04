import Foundation

/// Raises quiet recordings to a normal speech level before transcription, like a browser's auto gain.
/// Parakeet drifts into the wrong language on quiet input (-24 dB Spanish: 11 % → 3.6 % WER once raised).
/// Speech at a normal level is left untouched: re-leveling it changes words both ways for no net gain
/// (measured on 243 clips, see README "Accuracy").
enum Level {
    /// Speech quieter than this (RMS of the voiced frames) gets raised.
    static let quietDB: Float = -32
    /// Level the quiet speech is raised to (natural speech in the test set sits at -20…-25 dB).
    static let targetDB: Float = -23
    static let maxGainDB: Float = 30
    /// Below this the recording is silence or room noise: leave it alone rather than boost hiss.
    static let silenceDB: Float = -70

    /// Returns the samples to transcribe and the gain applied in dB.
    static func normalize(_ x: [Float]) -> (samples: [Float], gainDB: Float) {
        let frame = 320  // 20 ms at 16 kHz
        guard x.count >= frame * 5 else { return (x, 0) }
        var powers: [Float] = []
        powers.reserveCapacity(x.count / frame)
        var i = 0
        while i + frame <= x.count {
            var p: Float = 0
            for k in i..<(i + frame) { p += x[k] * x[k] }
            powers.append(p / Float(frame))
            i += frame
        }
        // Speech level = mean power of the loudest 30 % of frames, so pauses don't dilute it.
        powers.sort(by: >)
        let voiced = powers.prefix(max(1, powers.count * 3 / 10))
        let levelDB = 10 * log10(max(voiced.reduce(0, +) / Float(voiced.count), 1e-12))
        guard levelDB > silenceDB, levelDB < quietDB else { return (x, 0) }

        var gainDB = min(maxGainDB, targetDB - levelDB)
        // Keep the 99.9th-percentile sample under 0.9 so a single click doesn't cap the gain; rarer peaks are soft-limited.
        let mags = x.map(abs).sorted()
        let p999 = mags[min(mags.count - 1, mags.count * 999 / 1000)]
        if p999 > 0 { gainDB = min(gainDB, 20 * log10(0.9 / p999)) }
        guard abs(gainDB) >= 1 else { return (x, 0) }

        let g = pow(10, gainDB / 20)
        let knee: Float = 0.9
        let out = x.map { s -> Float in
            let y = s * g
            let a = abs(y)
            guard a > knee else { return y }
            return (y < 0 ? -1 : 1) * (knee + (1 - knee) * tanh((a - knee) / (1 - knee)))
        }
        return (out, gainDB)
    }
}
