import Foundation
import Synchronization
import Testing
import TactileCore
@testable import Tactile
@testable import TactileTransport
@testable import TactileCABI
import CTactileHeaders

/// Common-block byte `i` of a Bluetooth 0x31 report.
private func common(_ r: [UInt8], _ i: Int) -> UInt8 { r[OutputLayout.bluetoothCommonOffset + i] }

@Suite struct HapticsHandBackTests {
    /// The rumble-off report that precedes the 0x32 stream sets the
    /// haptics-select bit (SDL: disables audio haptics); a report with the bit
    /// clear must follow so the voice coils go back to audio haptics.
    @Test func suppressingLatchedRumbleRestoresAudioHaptics() async throws {
        let reports = Mutex<[[UInt8]]>([])
        let c = fakeConnection(1, send: { r in reports.withLock { $0.append(r) } })
        try await c.apply(OutputState(rumble: Rumble(left: 90, right: 40), lightbar: .defaultBlue))
        let before = reports.withLock { $0.count }
        await c.setRumbleSuppressed(true)
        let sent = reports.withLock { Array($0[before...]) }
        #expect(sent.count == 2)
        let off = try #require(sent.first), back = try #require(sent.last)
        #expect(common(off, OutputLayout.validFlag0) & OutputLayout.flag0HapticsSelect != 0)
        #expect(common(off, OutputLayout.motorLeft) == 0 && common(off, OutputLayout.motorRight) == 0)
        #expect(common(back, OutputLayout.validFlag0) & OutputLayout.flag0HapticsSelect == 0)
        #expect(common(back, OutputLayout.validFlag1) & OutputLayout.flag1Lightbar != 0) // owned state kept
        #expect(sent.allSatisfy { CRC32.verify($0, prefix: .output) })
        await c.close()
    }

    @Test func neutralizeDuringHapticsEndsWithHapticsSelectClear() async throws {
        let reports = Mutex<[[UInt8]]>([])
        let c = fakeConnection(1, send: { r in reports.withLock { $0.append(r) } })
        await c.setRumbleSuppressed(true)
        await c.neutralize()
        let last = try #require(reports.withLock { $0.last })
        #expect(common(last, OutputLayout.validFlag0) & OutputLayout.flag0HapticsSelect == 0)
        await c.close()
    }

    @Test func neutralizeWithoutHapticsSendsOneReport() async throws {
        let reports = Mutex<[[UInt8]]>([])
        let c = fakeConnection(1, send: { r in reports.withLock { $0.append(r) } })
        await c.neutralize()
        #expect(reports.withLock { $0.count } == 1)
        await c.close()
    }
}

/// get_info blocks on a semaphore: call it from a plain thread, never from a
/// cooperative-pool worker.
private func info(of box: ControllerBox, structSize: UInt32, presetVendor: UInt16 = 0) async -> tactile_controller_info {
    await withCheckedContinuation { cont in
        Thread.detachNewThread {
            let handle = OpaquePointer(Unmanaged.passRetained(box).toOpaque())
            var i = tactile_controller_info()
            i.struct_size = structSize
            i.vendor_id = presetVendor
            _ = TactileCABI.tactile_controller_get_info(handle, &i)
            TactileCABI.tactile_controller_release(handle)
            cont.resume(returning: i)
        }
    }
}

final class SentReports: Sendable {
    let list = Mutex<[[UInt8]]>([])
    var last: [UInt8]? { list.withLock { $0.last } }
    var isEmpty: Bool { list.withLock { $0.isEmpty } }
}

@Suite struct ABI03Tests {
    @Test func structSizesMatchTheHeaderAppendix() {
        #expect(MemoryLayout<tactile_input_state>.size == 88)
        #expect(MemoryLayout<tactile_input_state>.offset(of: \.headphones) == 72)
        #expect(MemoryLayout<tactile_input_state>.offset(of: \.host_time_ns) == 80)
        #expect(MemoryLayout<tactile_controller_info>.size == 116)
        #expect(MemoryLayout<tactile_controller_info>.offset(of: \.vendor_id) == 44)
        #expect(MemoryLayout<tactile_haptics_metrics>.size == 104)
        #expect(MemoryLayout<tactile_haptics_metrics>.offset(of: \.buffered_ms) == 72)
        #expect(MemoryLayout<tactile_speaker_stats>.size == 88)
        #expect(TactileCABI.tactile_abi_version() == 0x0000_0003)
        #expect(String(cString: TactileCABI.tactile_version_string()) == "0.3.0")
    }

    private func liveBox(_ reports: SentReports = SentReports(), transport: Transport = .bluetooth) -> (Controller, ControllerBox) {
        let info = device(1, transport: transport)
        let c = DeviceConnection(info: info, options: testOptions(),
                                 io: ConnectionIO(send: { r in reports.list.withLock { $0.append(r) } }))
        let controller = Controller(connection: c, info: info, id: "abi03-\(transport)")
        return (controller, ControllerBox(controller))
    }

    @Test func infoReportsIdentityAndCapabilities() async {
        let (controller, box) = liveBox()
        let rc = await info(of: box, structSize: UInt32(MemoryLayout<tactile_controller_info>.size))
        #expect(rc.vendor_id == 0x054C && rc.product_id == 0x0DF2)
        #expect(String(cString: withUnsafeBytes(of: rc.product) { Array($0.bindMemory(to: CChar.self)) + [0] }) == "Test Edge")
        let caps = rc.capabilities
        #expect(caps & TACTILE_CAP_EDGE_CONTROLS != 0)
        #expect(caps & TACTILE_CAP_HID_HAPTICS != 0)
        #expect(caps & TACTILE_CAP_USB_AUDIO_HAPTICS == 0)
        #expect(caps & TACTILE_CAP_HID_SPEAKER == 0)          // the fake descriptor has no 0x36
        #expect(caps & TACTILE_CAP_VIBRATION_V2 != 0)         // the Edge always uses v2
        #expect(rc.capabilities_unverified == caps)
        _ = box.invalidate()
        await controller.close()
    }

    @Test func oldCallersStructSizeIsHonoured() async {
        let (controller, box) = liveBox()
        let rc = await info(of: box, structSize: 44, presetVendor: 0xBEEF)   // ABI 0.2 caller
        #expect(rc.vendor_id == 0xBEEF)                         // untouched past the old size
        _ = box.invalidate()
        await controller.close()
    }

    @Test func setAudioWritesRoutingAndVolume() async throws {
        let reports = SentReports()
        let (controller, box) = liveBox(reports)
        let handle = OpaquePointer(Unmanaged.passRetained(box).toOpaque())
        var s = tactile_audio_settings(struct_size: UInt32(MemoryLayout<tactile_audio_settings>.size),
                                       headphone_volume: -1, speaker_volume: 200, mic_volume: -1,
                                       output_path: Int32(TACTILE_AUDIO_PATH_SPEAKER.rawValue))
        #expect(TactileCABI.tactile_controller_set_audio(handle, &s) == TACTILE_OK.rawValue)
        #expect(await eventually { !reports.isEmpty })
        let r = try #require(reports.last)
        #expect(common(r, OutputLayout.validFlag0) == OutputLayout.flag0SpeakerVolume | OutputLayout.flag0AudioControl)
        #expect(common(r, OutputLayout.speakerVolume) == 200 && common(r, OutputLayout.audioControl) == 0x30)
        s.output_path = 7
        #expect(TactileCABI.tactile_controller_set_audio(handle, &s) == TACTILE_ERR_INVALID_ARGUMENT.rawValue)
        s.output_path = -1; s.speaker_volume = -2
        #expect(TactileCABI.tactile_controller_set_audio(handle, &s) == TACTILE_ERR_INVALID_ARGUMENT.rawValue)
        TactileCABI.tactile_controller_release(handle)
        _ = box.invalidate()
        await controller.close()
    }

    @Test func speakerOpenIsRefusedWithoutReport0x36AndOverUSB() async {
        for transport in [Transport.bluetooth, .usb] {
            let (controller, box) = liveBox(transport: transport)
            let handle = OpaquePointer(Unmanaged.passRetained(box).toOpaque())
            var sp: OpaquePointer?
            #expect(TactileCABI.tactile_speaker_open(handle, nil, &sp) == TACTILE_ERR_UNSUPPORTED.rawValue)
            #expect(sp == nil)
            TactileCABI.tactile_speaker_close(nil)                  // safe no-op
            TactileCABI.tactile_controller_release(handle)
            _ = box.invalidate()
            await controller.close()
        }
    }

    @Test func inputStateCarriesHeadsetAndHostTime() async throws {
        let (controller, box) = liveBox()
        let conn = try #require(controller.connection)
        // Full Bluetooth 0x31 input (tools/gen_vectors.py "bt_in"): status1 = 0x01 (headphones).
        let btIn = hex("31 00 0a 14 1e 28 32 3c 07 22 21 05 00 00 00 00 00 01 00 fe ff 03 00 64 00 38 ff 00 20 04 03 02 01 00 05 e8 43 1f 83 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 18 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 5b 2c 66")
        let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #expect(await eventually {
            await conn.receive(btIn)
            return box.input() != nil
        })
        let s = try #require(box.input())
        #expect(s.headphones == 1 && s.microphone == 0)
        #expect(s.host_time_ns >= before - 1_000_000 && s.host_time_ns <= clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        _ = box.invalidate()
        await controller.close()
    }
}

private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }
