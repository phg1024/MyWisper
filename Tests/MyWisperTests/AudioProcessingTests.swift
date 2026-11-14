import AVFoundation
import Testing
@testable import MyWisper

struct AudioProcessingTests {
    func sine(_ seconds: Double, rate: Double, amplitude: Float = 0.5, hz: Double = 440) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * hz / rate)) * amplitude }
    }

    func chunks(_ samples: [Float], of size: Int) -> [[Float]] {
        stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
    }

    /// The waveform ran 10× too fast when AUHAL started handing over 10 ms at a time.
    @Test(arguments: [48000.0, 44100, 24000, 16000], [1, 160, 441, 480, 4096, 48000])
    func tenLevelsASecondHoweverItIsChunked(rate: Double, size: Int) {
        var meter = LevelMeter(sampleRate: rate)
        let levels = chunks(sine(2, rate: rate), of: size).flatMap { meter.add($0) }
        #expect(levels.count == 20)
    }

    @Test func levelFollowsLoudness() {
        var meter = LevelMeter(sampleRate: 16000)
        #expect(meter.add([Float](repeating: 0, count: 1600)) == [0])
        let quiet = meter.add(sine(0.1, rate: 16000, amplitude: 0.01))[0]
        let loud = meter.add(sine(0.1, rate: 16000, amplitude: 0.5))[0]
        #expect(quiet > 0 && quiet < loud)
        #expect(meter.add(sine(0.1, rate: 16000, amplitude: 1)) == [1])
    }

    @Test(arguments: [48000.0, 44100, 24000], [480, 441, 4096])
    func resamplesChunksTo16k(rate: Double, size: Int) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let resampler = try #require(Resampler(from: format))
        let out = chunks(sine(1, rate: rate), of: size).flatMap { resampler.convert($0) }
        // The filter holds back a few milliseconds at the end; nothing is lost or doubled at the seams.
        #expect(abs(out.count - 16000) < 160, "\(out.count) samples")
        // Still a clean 440 Hz tone: compare with the ideal one, ignoring the filter's delay.
        let ideal = sine(1, rate: 16000)
        let best = (0..<64).map { lag in
            zip(out.dropFirst(lag).prefix(14000), ideal.prefix(14000)).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / 14000
        }.min()!
        #expect(best < 1e-4, "mean squared error \(best)")
    }
}
