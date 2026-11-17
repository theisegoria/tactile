import Foundation
import Synchronization
import Testing
import TactileCore
@testable import Tactile
@testable import TactileTransport
@testable import TactileCABI
import CTactileHeaders

private func handle(_ box: ControllerBox) -> OpaquePointer { OpaquePointer(Unmanaged.passUnretained(box).toOpaque()) }

private let patternJSON = #"""
{"schemaVersion":1,"name":"abi","tracks":[{"name":"t","events":[
 {"time":0,"type":"effect","effect":{"click":{"intensity":1,"frequency":250}},"side":"both"},
 {"time":0,"type":"trigger","side":"right","effect":{"type":"weapon","start":2,"end":6,"strength":8}}
]}]}
"""#

@Suite struct ABI04Tests {
    @Test func presetsMatchSwiftPresets() {
        let order: [(tactile_trigger_preset, TriggerPreset)] = [
            (TACTILE_TRIGGER_PRESET_OFF, .off), (TACTILE_TRIGGER_PRESET_WEAPON, .weaponTrigger),
            (TACTILE_TRIGGER_PRESET_BOW, .bowDraw), (TACTILE_TRIGGER_PRESET_BRAKE, .brakePedal),
            (TACTILE_TRIGGER_PRESET_CLICK, .clickDetent), (TACTILE_TRIGGER_PRESET_MACHINE_GUN, .machineGun),
            (TACTILE_TRIGGER_PRESET_GALLOP, .gallop),
        ]
        #expect(order.count == TriggerPreset.allCases.count)
        for (c, swift) in order {
            var e = tactile_trigger_effect()
            #expect(tactile_trigger_from_preset(Int32(c.rawValue), &e) == TACTILE_OK.rawValue)
            #expect(withUnsafeBytes(of: e.bytes) { Array($0) } == swift.effect.bytes, "\(swift)")
        }
        #expect(TACTILE_ABI_VERSION_MINOR == 4)
    }

    @Test func patternLoadsFromFileWithClipsRelativeToIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abi04-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.tactilepattern")
        try Data(patternJSON.utf8).write(to: url)
        var p: OpaquePointer?
        #expect(tactile_pattern_load_file(url.path, &p) == TACTILE_OK.rawValue)
        #expect(tactile_pattern_duration(p) > 0.011 && tactile_pattern_duration(p) < 0.013)
        tactile_pattern_free(p)
        // A clip that does not exist fails the load with an I/O error.
        let withClip = #"{"schemaVersion":1,"tracks":[{"name":"a","events":[{"time":0,"type":"audio","clip":{"path":"missing.wav"}}]}]}"#
        var q: OpaquePointer?
        #expect(tactile_pattern_load_json(withClip, 0, dir.path, &q) == TACTILE_ERR_IO.rawValue)
        #expect(q == nil)
    }

    @Test func profileApplyJSONSendsLights() async throws {
        let reports = Mutex<[[UInt8]]>([])
        let c = Controller(connection: fakeConnection(1, send: { r in reports.withLock { $0.append(r) } }), info: device(1), id: "abi04")
        let box = ControllerBox(c)
        let json = #"{"name":"p","lightbar":{"red":10,"green":20,"blue":30},"rightTrigger":{"type":"weapon","start":2,"end":6,"strength":8},"hapticGain":0.5}"#
        #expect(tactile_profile_apply_json(handle(box), json, 0) == TACTILE_OK.rawValue)
        #expect(await eventually { reports.withLock { r in r.last.map { $0[OutputLayout.bluetoothCommonOffset + OutputLayout.lightbarRed] == 10 } ?? false } })
        let bad = #"{"name":"p","rightTrigger":{"type":"weapon","start":0,"end":1,"strength":8}}"#
        #expect(tactile_profile_apply_json(handle(box), bad, 0) == TACTILE_ERR_INVALID_ARGUMENT.rawValue)
        #expect(tactile_profile_apply_json(handle(box), #"{"schemaVersion":5}"#, 0) == TACTILE_ERR_VERSION.rawValue)
        #expect(tactile_profile_apply_file(handle(box), "/nonexistent/x.tactileprofile") == TACTILE_ERR_NOT_FOUND.rawValue)
        await box.invalidate().value
        await c.close()
    }

    @Test func patternPlayOverUSBReportsUnsupported() async throws {
        let c = Controller(connection: DeviceConnection(info: device(2, transport: .usb), options: testOptions(), io: ConnectionIO(send: { _ in })),
                           info: device(2, transport: .usb), id: "abi04-usb")
        let box = ControllerBox(c)
        var p: OpaquePointer?
        #expect(tactile_pattern_load_json(patternJSON, 0, nil, &p) == TACTILE_OK.rawValue)
        #expect(tactile_pattern_play(handle(box), p) == TACTILE_OK.rawValue)
        tactile_pattern_free(p)  // playback keeps its own reference
        #expect(await eventually { tactile_controller_last_error(handle(box)) == TACTILE_ERR_UNSUPPORTED.rawValue })
        #expect(tactile_pattern_is_playing(handle(box)) == 0)
        #expect(box.currentPattern() == nil)
        #expect(tactile_pattern_stop(handle(box)) == TACTILE_OK.rawValue)
        await box.invalidate().value
        await c.close()
    }

    @Test func boxReplacesAndStopsPatterns() throws {
        let c = Controller(connection: fakeConnection(3), info: device(3), id: "abi04-replace")
        let box = ControllerBox(c)
        let pattern = try HapticPattern(data: Data(patternJSON.utf8))
        let preview = try HapticPatternRenderer.renderOffline(pattern)
        let a = HapticPatternPlayer(pattern: pattern, preview: preview, mixer: c.haptics, output: nil)
        let b = HapticPatternPlayer(pattern: pattern, preview: preview, mixer: c.haptics, output: nil)
        a.start()
        box.setPattern(a)
        box.setPattern(b)
        #expect(!a.isPlaying)          // replaced pattern was stopped
        #expect(box.currentPattern() === b)
        box.stopPattern()
        #expect(box.currentPattern() == nil)
    }
}
