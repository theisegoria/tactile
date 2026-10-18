import Foundation
import Synchronization
import Testing
import TactileCore
@testable import Tactile
@testable import TactileTransport
@testable import TactileCABI
import CTactileHeaders

/// C teardown/callback draining blocks a thread while Swift tasks finish.
/// Never occupy a cooperative executor worker with that synchronous wait.
private func onBlockingThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: body()) }
    }
}

final class FakeDiscovery: Sendable {
    let stream: AsyncThrowingStream<ManagerDiscoveryEvent, any Error>
    let continuation: AsyncThrowingStream<ManagerDiscoveryEvent, any Error>.Continuation
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
}

func device(_ id: UInt64, transport: Transport = .bluetooth) -> DeviceInfo {
    DeviceInfo(deviceID: id, model: .dualSenseEdge, transport: transport, product: "Test Edge",
               serialNumber: "02-11-22-33-44-55", locationID: nil, reportDescriptor: Data(), isVirtual: false)
}

func testOptions() -> ConnectionOptions { var o = ConnectionOptions(); o.journal = nil; return o }

func fakeConnection(_ id: UInt64, options: ConnectionOptions = testOptions(),
                    send: @escaping @Sendable ([UInt8]) async throws(TransportError) -> Void = { _ in }) -> DeviceConnection {
    DeviceConnection(info: device(id), options: options, io: ConnectionIO(send: send))
}

func eventually(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Suite struct LifecycleTests {
    @Test func shutdownFinishesStreamsWithoutReentrantLockAndCanRestart() async {
        let sources = Mutex<[FakeDiscovery]>([])
        let manager = ControllerManager(options: testOptions(), discover: {
            let source = FakeDiscovery()
            sources.withLock { $0.append(source) }
            return source.stream
        })
        let ended = Mutex(0)
        let events = manager.events()
        let reader = Task { for await _ in events {}; ended.withLock { $0 += 1 } }
        #expect(await eventually { sources.withLock { $0.count == 1 } })
        async let first: Void = manager.shutdown()
        async let second: Void = manager.shutdown()
        _ = await (first, second)
        await reader.value
        #expect(ended.withLock { $0 } == 1)
        let nextEvents = manager.events()
        let nextReader = Task { for await _ in nextEvents {} }
        #expect(await eventually { sources.withLock { $0.count == 2 } })
        await manager.shutdown()
        await nextReader.value
    }

    @Test func transportFilterRunsBeforeFactory() async {
        let source = FakeDiscovery()
        let opened = Mutex(0)
        var options = testOptions(); options.allowedTransports = [.bluetooth]
        let manager = ControllerManager(options: options, discover: { source.stream })
        manager.start()
        source.continuation.yield(.connected(device(1, transport: .usb), { () async throws(TransportError) in
            opened.withLock { $0 += 1 }
            return fakeConnection(1)
        }))
        let connection = fakeConnection(2)
        source.continuation.yield(.connected(device(2), { connection }))
        #expect(await eventually { manager.controllers.count == 1 })
        #expect(opened.withLock { $0 } == 0)
        #expect(manager.controllers.first?.info.deviceID == 2)
        await manager.shutdown()
    }

    @Test func reconnectFirstControllerAndNeutralPolicy() async throws {
        let source = FakeDiscovery()
        var options = testOptions(); options.restoreOutputOnReconnect = false
        let manager = ControllerManager(options: options, discover: { source.stream })
        manager.start()
        let first = fakeConnection(1, options: options)
        source.continuation.yield(.connected(device(1), { first }))
        #expect(await eventually { manager.controllers.count == 1 })
        let controller = try #require(manager.controllers.first)
        try await controller.setRumble(Rumble(left: 153, right: 102))
        source.continuation.yield(.disconnected(1))
        #expect(await eventually { !controller.isConnected })
        let waiter = Task { await manager.firstController(timeout: .seconds(1)) }
        let second = fakeConnection(2, options: options)
        source.continuation.yield(.connected(device(2), { second }))
        let reconnected = await waiter.value
        #expect(reconnected === controller)
        #expect(await second.ownedOutput == OutputState())
        #expect(!controller.hapticsRunning)
        await manager.shutdown()
    }

    @Test func defaultReconnectRestoresOwnedState() async throws {
        let first = fakeConnection(1)
        let controller = Controller(connection: first, info: device(1), id: "restore")
        try await controller.setLightbar(.init(red: 51, green: 128, blue: 204))
        let expected = await first.ownedOutput
        _ = controller.connectionLost(deviceID: 1)
        let second = fakeConnection(2)
        await controller.replaceConnection(second, info: device(2))
        #expect(await second.ownedOutput.lightbar == expected.lightbar)
        await controller.close()
    }

    @Test func lateOpenDuringShutdownIsClosedAndNeverAnnounced() async {
        let source = FakeDiscovery()
        let opening = Mutex(false)
        let manager = ControllerManager(options: testOptions(), discover: { source.stream })
        let events = manager.events()
        let count = Mutex(0)
        let reader = Task { for await _ in events { count.withLock { $0 += 1 } } }
        let connection = fakeConnection(1)
        source.continuation.yield(.connected(device(1), { () async throws(TransportError) in
            opening.withLock { $0 = true }
            // A real open may finish even after its caller was cancelled.
            await Task.detached { try? await Task.sleep(for: .milliseconds(80)) }.value
            return connection
        }))
        #expect(await eventually { opening.withLock { $0 } })
        await manager.shutdown()
        await reader.value
        #expect(count.withLock { $0 } == 0)
        #expect(await !connection.isOpen)
    }

    @Test func concurrentConnectionCloseWaitsForNeutralSend() async {
        let sent = Mutex(0)
        let connection = fakeConnection(1, send: { _ in
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
            sent.withLock { $0 += 1 }
        })
        async let a: Void = connection.close()
        async let b: Void = connection.close()
        _ = await (a, b)
        #expect(sent.withLock { $0 } == 1)
        #expect(await !connection.isOpen)
    }

    @Test func silentMicScanExpires() async {
        let connection = fakeConnection(1)
        let controller = Controller(connection: connection, info: device(1), id: "scan")
        let start = ContinuousClock.now
        _ = await controller.scanForMicUplink(duration: .milliseconds(40))
        #expect(ContinuousClock.now - start < .milliseconds(250))
        await controller.close()
    }

    @Test func retainedCHandleIsInvalidatedByContextShutdown() async throws {
        let source = FakeDiscovery()
        let manager = ControllerManager(options: testOptions(), discover: { source.stream })
        let context = ContextBox(manager: manager)
        let connection = fakeConnection(1)
        source.continuation.yield(.connected(device(1), { connection }))
        #expect(await eventually { context.count == 1 })
        let box = try #require(context.box(at: 0))
        let handle = OpaquePointer(Unmanaged.passRetained(box).toOpaque())
        defer { TactileCABI.tactile_controller_release(handle) }
        await onBlockingThread { context.shutdown() }
        #expect(box.isInvalidated)
        #expect(!box.isLive)
        #expect(TactileCABI.tactile_controller_set_rumble(handle, 1, 1) == TACTILE_ERR_NOT_CONNECTED.rawValue)
        #expect(box.enqueue({}) == TACTILE_ERR_NOT_CONNECTED.rawValue)
    }
}

private final class CallbackProbe: @unchecked Sendable {
    let entered = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    let count = Mutex(0)
    func invoke() {
        count.withLock { $0 += 1 }
        entered.withLock { $0 = true }
        _ = release.wait(timeout: .now() + 2)
    }
}

private func blockingTestCallback(_ user: UnsafeMutableRawPointer?, _ controller: OpaquePointer?, _ event: Int32) {
    guard let user else { return }
    Unmanaged<CallbackProbe>.fromOpaque(user).takeUnretainedValue().invoke()
}

@Suite struct CHandleLifecycleTests {
    @Test func clearingCallbackWaitsForItsInFlightInvocation() async {
        let source = FakeDiscovery()
        let manager = ControllerManager(options: testOptions(), discover: { source.stream })
        let context = ContextBox(manager: manager)
        let probe = CallbackProbe()
        context.setCallback(blockingTestCallback, Unmanaged.passUnretained(probe).toOpaque())
        let connection = fakeConnection(1)
        source.continuation.yield(.connected(device(1), { connection }))
        #expect(await eventually { probe.entered.withLock { $0 } })
        let cleared = Mutex(false)
        let clear = Task {
            await onBlockingThread {
                context.setCallback(nil, nil)
                cleared.withLock { $0 = true }
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!cleared.withLock { $0 })
        probe.release.signal()
        await clear.value
        source.continuation.yield(.disconnected(1))
        await onBlockingThread { context.shutdown() }
        #expect(probe.count.withLock { $0 } == 1)
    }

    @Test func oldInputTaskCannotEraseNewConnectionSnapshot() async {
        let first = fakeConnection(1)
        let controller = Controller(connection: first, info: device(1), id: "snapshots")
        let box = ControllerBox(controller)
        let second = fakeConnection(2)
        await controller.replaceConnection(second, info: device(2))
        box.restartInput()
        let report: [UInt8] = [1, 42, 127, 1, 255, 16, 2, 253, 16, 240]
        #expect(await eventually {
            await second.receive(report)
            return box.input()?.left_x == 42
        })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(box.input()?.left_x == 42)
        _ = box.invalidate()
        await controller.close()
    }
}

@Suite struct OwnedOutputCleanupTests {
    @Test func neutralizeClearsOwnedLEDsAndExperimentalAudio() async throws {
        let reports = Mutex<[[UInt8]]>([])
        let connection = fakeConnection(1, send: { report in reports.withLock { $0.append(report) } })
        try await connection.apply(OutputState(playerLEDs: .player(3), muteLED: .on,
                                              audio: AudioSettings(speakerVolume: 160, micVolume: 64, outputPath: .speaker)))
        await connection.neutralize()
        let last = try #require(reports.withLock { $0.last })
        let base = OutputLayout.bluetoothCommonOffset
        #expect(last[base + OutputLayout.playerLEDs] == 0)
        #expect(last[base + OutputLayout.muteLED] == 0)
        #expect(last[base + OutputLayout.speakerVolume] == 0)
        #expect(last[base + OutputLayout.micVolume] == 0)
        #expect(last[base + OutputLayout.validFlag0] & 0xE0 == 0xE0)
        #expect(last[base + OutputLayout.validFlag1] & 0x11 == 0x11)
        await connection.close()
    }
}
