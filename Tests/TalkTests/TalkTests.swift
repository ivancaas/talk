import Carbon.HIToolbox
import Testing
@testable import Talk

struct HotkeyTests {
    @Test func parsesModifiersAndKey() throws {
        let (key, mods) = try #require(Hotkey.parse("ctrl+opt+d"))
        #expect(key == 0x02)
        #expect(mods == UInt32(controlKey) | UInt32(optionKey))
    }

    @Test func defaultAndFunctionKeys() {
        #expect(Hotkey.parse("opt+space")?.0 == UInt32(kVK_Space))
        #expect(Hotkey.parse("f13")?.0 == 0x69)
        #expect(Hotkey.parse(" Cmd + Shift + F5 ")?.1 == UInt32(cmdKey) | UInt32(shiftKey))
    }

    @Test func rejectsTyposAndAmbiguousSpecs() {
        #expect(Hotkey.parse("optn+space") == nil, "a misspelt modifier must not fall back to bare Space")
        #expect(Hotkey.parse("opt+a+b") == nil)
        #expect(Hotkey.parse("opt+") == nil)
        #expect(Hotkey.parse("") == nil)
    }
}

struct TranscribeCLITests {
    @Test func parsesOptions() throws {
        let o = try TranscribeCLI.parse(["-f", "srt", "-o", "out.srt", "talk.m4a"])
        #expect(o.format == .srt)
        #expect(o.output == "out.srt")
        #expect(o.inputs == ["talk.m4a"])
    }

    @Test func rejectsBadArguments() {
        #expect(throws: (any Error).self) { try TranscribeCLI.parse([]) }
        #expect(throws: (any Error).self) { try TranscribeCLI.parse(["-f", "doc", "a.wav"]) }
        #expect(throws: (any Error).self) { try TranscribeCLI.parse(["-o", "x.txt", "a.wav", "b.wav"]) }
        #expect(throws: (any Error).self) { try TranscribeCLI.parse(["--nope", "a.wav"]) }
    }

    @Test func doubleDashTakesTheRestAsInputs() throws {
        #expect(try TranscribeCLI.parse(["--", "-weird.wav"]).inputs == ["-weird.wav"])
    }

    @Test func timecodes() {
        #expect(TranscribeCLI.timecode(3723.4567, sep: ",") == "01:02:03,457")
        #expect(TranscribeCLI.timecode(0, sep: ".") == "00:00:00.000")
        #expect(TranscribeCLI.timecode(-1, sep: nil) == "00:00:00")
    }
}

struct LevelTests {
    private func tone(amplitude: Float, seconds: Double = 1) -> [Float] {
        (0..<Int(16000 * seconds)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16000) }
    }

    @Test func raisesQuietSpeech() {
        let (out, gain) = Level.normalize(tone(amplitude: 0.01))  // ≈ -43 dB
        #expect(gain > 10)
        #expect(out.map(abs).max()! > 0.05)
    }

    @Test func leavesNormalSpeechAlone() {
        let x = tone(amplitude: 0.1)  // ≈ -23 dB
        let (out, gain) = Level.normalize(x)
        #expect(gain == 0)
        #expect(out == x)
    }

    @Test func leavesSilenceAlone() {
        #expect(Level.normalize([Float](repeating: 0, count: 16000)).gainDB == 0)
    }
}
