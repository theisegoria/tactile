import Foundation
import Synchronization
import Testing
import TactileCore
@testable import TactileAudio

@Suite struct AudioValidationTests {
    @Test func invalidFormatsThrowBeforeSystemCalls() {
        let formats = [
            OpusStreamFormat(sampleRate: .nan, channels: 2),
            OpusStreamFormat(sampleRate: .infinity, channels: 2),
            OpusStreamFormat(sampleRate: -1, channels: 2),
            OpusStreamFormat(sampleRate: 48_000, channels: -1),
            OpusStreamFormat(sampleRate: 48_000, channels: .max),
            OpusStreamFormat(sampleRate: 48_000, channels: 0),
            OpusStreamFormat(sampleRate: 48_000, channels: 2, frameMilliseconds: .nan),
            OpusStreamFormat(sampleRate: 48_000, channels: 2, frameMilliseconds: 1e30)
        ]
        for format in formats {
            #expect(format.framesPerPacket == 0)
            #expect(throws: OpusCodecError.self) { try OpusEncoder(format: format) }
            #expect(throws: OpusCodecError.self) { try OpusDecoder(format: format) }
        }
        for rate in [Int.min, -1, 0, 5999, 512001, Int.max] {
            #expect(throws: OpusCodecError.self) { try OpusEncoder(bitRate: rate) }
        }
    }

    @Test func incompleteStereoFrameDoesNotChangePendingAudio() throws {
        let encoder = try OpusEncoder()
        #expect(throws: OpusCodecError.self) { try encoder.encode(interleaved: Array(repeating: 0.2, count: 959)) }
        #expect(try encoder.flush().isEmpty)
        #expect(try encoder.encode(interleaved: Array(repeating: 0.2, count: 960)).count == 1)
        #expect(try encoder.flush().isEmpty)
    }

    @Test func silentRecordingHasIndependentDeadline() async throws {
        let terminated = Mutex(false)
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        continuation.onTermination = { _ in terminated.withLock { $0 = true } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silent-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url); continuation.finish() }
        let decoder = try MicUplinkDecoder(extractor: .init(reportID: 0x35, tocOffset: 2, lengthOffset: 1))
        let start = ContinuousClock.now
        let stats = try await decoder.record(reports: stream, to: url, duration: .milliseconds(40))
        #expect(ContinuousClock.now - start < .milliseconds(250))
        #expect(stats.packetsDecoded == 0)
        for _ in 0..<20 where !terminated.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
        #expect(terminated.withLock { $0 })
    }

    @Test func recordingCancellationEndsSilentForwarder() async throws {
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        let terminated = Mutex(false)
        continuation.onTermination = { _ in terminated.withLock { $0 = true } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url); continuation.finish() }
        let task = Task {
            let decoder = try MicUplinkDecoder(extractor: .init(reportID: 0x35, tocOffset: 2, lengthOffset: 1))
            return try await decoder.record(reports: stream, to: url, duration: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; Issue.record("recording must throw on cancellation") }
        catch is CancellationError {} catch { Issue.record("unexpected error: \(error)") }
        for _ in 0..<20 where !terminated.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
        #expect(terminated.withLock { $0 })
    }

    @Test func droppedSpeakerPacketsStillConsumePlaybackTime() async throws {
        let stream = SpeakerStream(framing: .init(reportLength: 8), bitRate: 256_000) { _ in }
        let start = ContinuousClock.now
        let stats = try await stream.play(chunks: (0..<10).map { _ in Array(repeating: Float(0.1), count: 960) })
        #expect(stats.packetsDroppedOversize >= 10)
        #expect(ContinuousClock.now - start >= .milliseconds(80))
    }

    @Test func invalidSpeakerFramingIsNotCountedAsOversize() async throws {
        let stream = SpeakerStream(framing: .init(reportLength: 3)) { _ in }
        do { _ = try await stream.play(chunks: [[Float](repeating: 0, count: 960)]); Issue.record("expected invalid framing") }
        catch SpeakerAudioReportBuilder.BuildError.badFraming {} catch { Issue.record("unexpected error: \(error)") }
    }
}
