public import CoreHID
public import TactileCore
import Foundation

/// How the connection coexists with other HID clients (macOS's driver,
/// GameController, Steam…). See docs/Coexistence.md.
public enum AccessMode: String, Sendable, Codable {
    /// Default. Do not seize the device; GameController and others keep working.
    /// Conflicting writers are detected and reported, not blocked.
    case shared
    /// `seizeDevice()`: exclusive access. GameController and Steam stop seeing the
    /// controller, so the host must take standard input from this library.
    case exclusive
}

/// Tunables for a connection.
public struct ConnectionOptions: Sendable {
    public var mode: AccessMode = .shared
    /// Upper bound on report 0x31 frequency. Extra updates are coalesced (the
    /// latest state is always delivered), never queued unboundedly.
    public var maxOutputReportsPerSecond: Double = 125
    /// Re-send owned output state periodically so that another writer cannot
    /// silently override it for long. `nil` disables re-assertion.
    public var reassertInterval: Duration? = nil
    /// Verify CRCs on Bluetooth input reports.
    public var verifyInputCRC = true
    /// Crash-recovery journal. `nil` disables it.
    public var journal: CleanupJournal? = CleanupJournal()
    /// Lightbar colour restored on close.
    public var restoreLightbar: LightbarColor = .defaultBlue
    /// Timeout for individual get/set report requests.
    public var requestTimeout: Duration = .seconds(2)

    public init() {}
}

/// One decoded input report.
public struct InputEvent: Sendable {
    public var state: InputState
    /// Present when the report carried IMU data.
    public var imu: CalibratedIMU?
    /// The raw report, report ID first.
    public var raw: [UInt8]
    public var timestamp: SuspendingClock.Instant
}

/// One raw input report (report ID first), before any parsing.
public struct RawInputReport: Sendable {
    public var bytes: [UInt8]
    public var timestamp: SuspendingClock.Instant
}

/// An open controller. All methods are safe to call from any task.
public actor DeviceConnection {
    public nonisolated let info: DeviceInfo
    public nonisolated let options: ConnectionOptions
    public private(set) var firmware: FirmwareInfo?
    public private(set) var calibration: IMUCalibration = .defaults
    public private(set) var pairing: PairingInfo?
    public private(set) var features: FeatureSet
    public private(set) var isOpen = true
    /// Last decoded input.
    public private(set) var lastInput: InputState?
    /// Observed input report IDs, in order of first appearance (diagnostics).
    public private(set) var observedReportIDs: [UInt8] = []

    /// The CoreHID client. Released on close or disconnect: CoreHID has no
    /// unseize call, so dropping the client is what ends an exclusive seize.
    private var client: HIDDeviceClient?
    private var builder: OutputReportBuilder
    private var limiter: RateLimiter
    private var desired = OutputState()
    private var flushTask: Task<Void, Never>?
    /// Identity of the current `flushTask`; bumped whenever it is replaced or
    /// cleared so a stale deferred task cannot clobber a newer one.
    private var flushGeneration: UInt64 = 0
    /// Set for the whole of `close()`: no output other than the final neutral
    /// report may be issued once closing has begun.
    private var closing = false
    /// Incremented each time an output report 0x31/0x02 is issued, so a neutral
    /// send can tell whether something else went out after it.
    private var outputSequence: UInt64 = 0
    /// The last rumble value actually written (the motors latch it).
    private var latchedRumble: Rumble?
    private var reassertTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<InputEvent>.Continuation] = [:]
    private var rawSubscribers: [UUID: AsyncStream<RawInputReport>.Continuation] = [:]
    private var experimentalLimiter = RateLimiter(maxPerSecond: 250, burst: 4)
    private var lightbarReleased = false
    private var suppressRumble = false
    private let clock = ContinuousClock()
    private let epoch = ContinuousClock.now

    /// Stable identity across reconnects: the controller's Bluetooth address.
    public var address: MACAddress? { pairing?.address ?? info.serialMAC }

    private var journalKey: String { address?.description ?? info.serialNumber ?? "id-\(info.deviceID)" }

    private init(client: HIDDeviceClient, info: DeviceInfo, options: ConnectionOptions) {
        self.client = client
        self.info = info
        self.options = options
        features = FeatureSet.resolve(model: info.model, firmware: nil)
        builder = OutputReportBuilder(features: features)
        limiter = RateLimiter(maxPerSecond: options.maxOutputReportsPerSecond, burst: 3)
    }

    // MARK: Open / close

    /// Opens a controller: optionally seizes it, starts the input stream, reads
    /// firmware, pairing and calibration (which switches Bluetooth input to the
    /// full 0x31 report), and performs crash recovery if needed.
    public static func open(
        _ ref: HIDDeviceClient.DeviceReference, info: DeviceInfo, options: ConnectionOptions = .init()
    ) async throws(TransportError) -> DeviceConnection {
        if InputMonitoringPermission.status == .denied { throw .inputMonitoringDenied }
        guard let client = HIDDeviceClient(deviceReference: ref) else {
            throw InputMonitoringPermission.status == .granted ? .deviceUnavailable : .inputMonitoringDenied
        }
        let c = DeviceConnection(client: client, info: info, options: options)
        try await c.start(client)
        return c
    }

    deinit {
        flushTask?.cancel()
        reassertTask?.cancel()
        monitorTask?.cancel()
    }

    private func start(_ client: HIDDeviceClient) async throws(TransportError) {
        if options.mode == .exclusive {
            do { try await client.seizeDevice() } catch { throw Self.map(error) }
        }
        startMonitoring(client)
        do {
            try await initialize()
        } catch {
            // Do not leave an orphaned monitor task holding the client (and
            // with it the seize) alive after a failed open.
            await releaseDevice()
            throw error
        }
    }

    private func initialize() async throws(TransportError) {
        // Firmware first so the feature set is right before any output.
        if let fw = try? await getFeatureReport(FirmwareInfo.featureReportID, length: FirmwareInfo.length) {
            firmware = try? FirmwareInfo(featureReport: fw)
        }
        features = FeatureSet.resolve(model: info.model, firmware: firmware)
        builder.features = features
        if let p = try? await getFeatureReport(PairingInfo.featureReportID, length: PairingInfo.length) {
            pairing = try? PairingInfo(featureReport: p)
        }
        // Reading 0x05 is also what switches Bluetooth input from 0x01 to 0x31.
        do {
            let cal = try await getFeatureReport(IMUCalibration.featureReportID, length: IMUCalibration.featureReportLength)
            calibration = (try? IMUCalibration(featureReport: cal)) ?? .defaults
        } catch .inputMonitoringDenied {
            throw .inputMonitoringDenied
        } catch {
            calibration = .defaults
        }
        if let j = options.journal, j.isDirty(journalKey) {
            // Only forget the record once the neutral report actually went out;
            // otherwise the next open (or this session's close) retries it.
            let seq = await sendNeutral()
            if seq != nil { j.markClean(journalKey) }
        }
        if let interval = options.reassertInterval {
            reassertTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    await self.reassert()
                }
            }
        }
    }

    /// Returns the controller to neutral (triggers off, rumble off, lightbar
    /// restored), releases the device (ending an exclusive seize) and ends all
    /// input streams.
    public func close() async {
        guard isOpen, !closing else { return }
        // Stop every other source of output before the neutral report, so
        // nothing (a deferred flush, the re-assert timer, a concurrent apply)
        // can land after it while the send is suspended.
        closing = true
        cancelFlush()
        reassertTask?.cancel()
        reassertTask = nil
        desired = OutputState()
        if await sendNeutral() != nil {
            options.journal?.markClean(journalKey)
        }
        // On failure the journal stays dirty so the next open neutralises.
        isOpen = false
        finishSubscribers()
        await releaseDevice()
    }

    /// Sends the neutral state now, bypassing the rate limiter, and forgets all
    /// owned output state. The connection stays open.
    public func neutralize() async {
        guard isOpen, !closing else { return }
        cancelFlush()
        // Reset before the await so a patch applied while the send is in flight
        // is kept rather than wiped afterwards.
        desired = OutputState()
        guard let seq = await sendNeutral() else { return }
        // Only mark clean if nothing else was sent after the neutral report.
        if seq == outputSequence { options.journal?.markClean(journalKey) }
    }

    /// Sends the neutral report, ignoring rumble suppression (neutral must
    /// always stop the motors). Returns its output sequence number on success.
    private func sendNeutral() async -> UInt64? {
        do {
            return try await sendNow(.neutral(restoreLightbar: options.restoreLightbar), honorSuppression: false)
        } catch {
            return nil
        }
    }

    /// Cancels background tasks and drops the CoreHID client. Waits for the
    /// monitor task (cancellation ends its notification stream) so that its
    /// reference to the client is gone too, which ends any seize.
    private func releaseDevice() async {
        isOpen = false
        cancelFlush()
        reassertTask?.cancel()
        reassertTask = nil
        let monitor = monitorTask
        monitorTask = nil
        monitor?.cancel()
        client = nil
        await monitor?.value
    }

    // MARK: Input

    /// A new subscription to decoded input. Each call returns an independent stream.
    public func inputEvents(bufferingNewest n: Int = 64) -> AsyncStream<InputEvent> {
        let (stream, cont) = AsyncStream<InputEvent>.makeStream(bufferingPolicy: .bufferingNewest(n))
        guard isOpen else {
            cont.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    /// EXPERIMENTAL (gate 6): every input report as received, including report
    /// IDs the parser does not understand (for example a microphone uplink).
    public func rawInputReports(bufferingNewest n: Int = 256) -> AsyncStream<RawInputReport> {
        let (stream, cont) = AsyncStream<RawInputReport>.makeStream(bufferingPolicy: .bufferingNewest(n))
        guard isOpen, !closing else {
            cont.finish()
            return stream
        }
        let id = UUID()
        rawSubscribers[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { await self?.removeRawSubscriber(id) }
        }
        return stream
    }

    private func removeRawSubscriber(_ id: UUID) { rawSubscribers[id] = nil }

    private func finishSubscribers() {
        for c in subscribers.values { c.finish() }
        subscribers.removeAll()
        for c in rawSubscribers.values { c.finish() }
        rawSubscribers.removeAll()
    }

    private func startMonitoring(_ client: HIDDeviceClient) {
        monitorTask = Task { [weak self] in
            do {
                let stream = await client.monitorNotifications(
                    reportIDsToMonitor: [HIDReportID.allReports], elementsToMonitor: [])
                for try await n in stream {
                    guard case .inputReport(let id, let data, let ts) = n else { continue }
                    await self?.handleInput(id: id?.rawValue, data: data, timestamp: ts)
                }
            } catch {}
            await self?.didDisconnect()
        }
    }

    private func didDisconnect() {
        isOpen = false
        cancelFlush()
        reassertTask?.cancel()
        reassertTask = nil
        monitorTask = nil
        client = nil
        finishSubscribers()
    }

    private func handleInput(id: UInt8?, data: Data, timestamp: SuspendingClock.Instant) {
        var bytes = [UInt8](data)
        if let id, bytes.first != id { bytes.insert(id, at: 0) }
        guard let rid = bytes.first else { return }
        if !observedReportIDs.contains(rid) { observedReportIDs.append(rid) }
        if !rawSubscribers.isEmpty {
            let raw = RawInputReport(bytes: bytes, timestamp: timestamp)
            for c in rawSubscribers.values { c.yield(raw) }
        }
        guard let state = try? InputParser.parse(
            bytes, transport: info.transport, model: info.model, verifyCRC: options.verifyInputCRC)
        else { return }
        lastInput = state
        let event = InputEvent(state: state, imu: state.imu.map(calibration.apply), raw: bytes, timestamp: timestamp)
        for c in subscribers.values { c.yield(event) }
    }

    // MARK: Feature reports

    /// Reads a feature report, normalised to start with its ID, with the
    /// Bluetooth CRC verified and stripped.
    public func getFeatureReport(_ id: UInt8, length: Int?) async throws(TransportError) -> [UInt8] {
        guard let rid = HIDReportID(rawValue: id) else { throw .notSupported("report ID 0") }
        guard let client else { throw .closed }
        let data: Data
        do {
            data = try await client.dispatchGetReportRequest(type: .feature, id: rid, timeout: options.requestTimeout)
        } catch {
            throw Self.map(error)
        }
        // The protocol lengths (41 for 0x05, 20 for 0x09, 64 for 0x20) already
        // include the trailing CRC on Bluetooth (the Linux driver reads the CRC
        // at length - 4), so they are passed through unchanged. Inflating them
        // would defeat normalize()'s stripped-ID detection.
        let bytes = FeatureReportFraming.normalize([UInt8](data), reportID: id, expectedLength: length)
        do {
            return try FeatureReportFraming.unwrap(bytes, transport: info.transport)
        } catch {
            // Some stacks strip the CRC already; accept the raw bytes if they parse.
            if info.transport == .bluetooth, case .badCRC = error { return bytes }
            throw .parse(error)
        }
    }

    // MARK: Output

    /// The output fields this connection currently owns.
    public var ownedOutput: OutputState { desired }

    /// Merges `patch` into the owned output state and schedules a report.
    /// Reports are rate-limited and coalesced; the latest state always goes out.
    public func apply(_ patch: OutputState) async throws(TransportError) {
        guard isOpen, !closing else { throw .closed }
        desired = desired.merging(patch)
        if patch.lightbar != nil, !lightbarReleased, info.transport == .bluetooth {
            desired.releaseLightbarAnimation = true
        }
        if Self.isNonNeutral(desired) { options.journal?.markDirty(journalKey) }
        try await flush()
    }

    /// Stops owning the given fields (their flags are cleared in later reports).
    public func relinquish(rumble: Bool = false, triggers: Bool = false, lightbar: Bool = false,
                           playerLEDs: Bool = false, muteLED: Bool = false) {
        if rumble { desired.rumble = nil }
        if triggers { desired.leftTrigger = nil; desired.rightTrigger = nil }
        if lightbar { desired.lightbar = nil }
        if playerLEDs { desired.playerLEDs = nil; desired.playerLEDBrightness = nil }
        if muteLED { desired.muteLED = nil }
    }

    /// While the audio-haptics stream runs, legacy rumble is omitted from 0x31
    /// (see docs/Haptics.md, arbitration policy).
    ///
    /// A cleared valid flag leaves the motors at their last value, so turning
    /// suppression on first writes rumble off if the motors were left running;
    /// otherwise that latched rumble would add to the mixer's emulated rumble.
    public func setRumbleSuppressed(_ suppressed: Bool) async {
        let wasSuppressed = suppressRumble
        suppressRumble = suppressed
        guard isOpen, !closing else { return }
        if suppressed, !wasSuppressed, let r = latchedRumble, r != .off {
            cancelFlush()
            var s = desired
            s.rumble = .off
            _ = try? await sendNow(s, honorSuppression: false)
            return
        }
        try? await flush()
    }

    /// Re-sends the owned state (used by the re-assert timer and after conflicts).
    public func reassert() async {
        guard isOpen, !closing, desired != OutputState() else { return }
        try? await flush()
    }

    private func flush() async throws(TransportError) {
        guard isOpen, !closing else { throw .closed }
        let now = UInt64((clock.now - epoch).nanoseconds)
        if limiter.tryAcquire(now: now) {
            cancelFlush()
            try await sendNow(desired)
            return
        }
        guard flushTask == nil else { return }  // a deferred flush will pick up the latest state
        let delay = limiter.delayUntilAvailable(now: now)
        flushGeneration &+= 1
        let generation = flushGeneration
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .nanoseconds(Int64(delay)))
            guard !Task.isCancelled else { return }
            await self?.deferredFlush(generation: generation)
        }
    }

    /// Cancels and forgets the pending deferred flush, if any.
    private func cancelFlush() {
        flushTask?.cancel()
        flushTask = nil
        flushGeneration &+= 1
    }

    private func deferredFlush(generation: UInt64) async {
        // A task that passed its cancellation check just before being cancelled
        // or replaced must not clear a newer task or send after close.
        guard generation == flushGeneration, isOpen, !closing else { return }
        flushTask = nil
        flushGeneration &+= 1
        try? await flush()
    }

    /// Builds and sends an output report now, bypassing the rate limiter.
    /// Returns the report's output sequence number.
    @discardableResult
    private func sendNow(_ state: OutputState, honorSuppression: Bool = true) async throws(TransportError) -> UInt64 {
        var s = state
        if honorSuppression, suppressRumble { s.rumble = nil }
        let report = builder.build(s, transport: info.transport)
        outputSequence &+= 1
        let seq = outputSequence
        try await setReport(report)
        if let r = s.rumble { latchedRumble = r }
        if s.releaseLightbarAnimation {
            lightbarReleased = true
            desired.releaseLightbarAnimation = false
        }
        return seq
    }

    /// Sends an audio-haptics report 0x32 (Bluetooth only). The report must
    /// already carry a valid CRC; invalid reports are rejected, never sent.
    public func sendHapticsReport(_ report: [UInt8]) async throws(TransportError) {
        guard isOpen, !closing else { throw .closed }
        guard info.transport == .bluetooth else { throw .notSupported("audio haptics over USB use the USB audio interface") }
        guard report.first == HapticsFormat.reportID else { throw .notSupported("not a 0x32 report") }
        try await setReport(report)
    }

    /// Report IDs with dedicated, validated send paths; the experimental path
    /// refuses them so it cannot bypass rate limiting or state ownership.
    public static let reservedOutputReportIDs: Set<UInt8> = [OutputLayout.bluetoothReportID, OutputLayout.usbReportID, HapticsFormat.reportID]

    /// EXPERIMENTAL (gate 6): sends a raw output report such as speaker audio
    /// (0x36). Bluetooth reports must carry a valid CRC. Capped at 250 reports/s;
    /// reports over the cap are refused with `ioFailure`, never queued.
    public func sendExperimentalOutputReport(_ report: [UInt8]) async throws(TransportError) {
        guard isOpen, !closing else { throw .closed }
        guard let id = report.first, !Self.reservedOutputReportIDs.contains(id) else {
            throw .notSupported("use the dedicated API for report 0x\(String(report.first ?? 0, radix: 16))")
        }
        let now = UInt64((clock.now - epoch).nanoseconds)
        guard experimentalLimiter.tryAcquire(now: now) else { throw .ioFailure("experimental output rate limit exceeded") }
        try await setReport(report)
    }

    private func setReport(_ report: [UInt8]) async throws(TransportError) {
        guard let id = report.first, let rid = HIDReportID(rawValue: id) else { throw .notSupported("empty report") }
        guard let client else { throw .closed }
        if info.transport == .bluetooth, !CRC32.verify(report, prefix: .output) {
            throw .notSupported("refusing to send a Bluetooth report without a valid CRC")
        }
        do {
            try await client.dispatchSetReportRequest(
                type: .output, id: rid, data: Data(report), timeout: options.requestTimeout)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: Diagnostics

    /// Scans the IORegistry for other processes holding this controller open.
    public nonisolated func conflicts() -> ConflictReport {
        ConflictDetector.scan(model: info.model, serialNumber: info.serialNumber)
    }

    static func isNonNeutral(_ s: OutputState) -> Bool {
        if let r = s.rumble, r != .off { return true }
        if let t = s.leftTrigger, t != .off { return true }
        if let t = s.rightTrigger, t != .off { return true }
        if s.lightbar != nil || s.playerLEDs != nil || s.muteLED != nil { return true }
        return false
    }

    static func map(_ error: any Error) -> TransportError {
        if let e = error as? TransportError { return e }
        guard let h = error as? HIDDeviceError else { return .ioFailure(String(describing: error)) }
        switch h {
        case .notPermitted, .notPrivileged: return .inputMonitoringDenied
        case .exclusiveAccess, .busy: return .exclusiveAccessHeldByAnotherProcess
        case .timeout, .notResponding: return .timeout
        case .notReady, .noPower, .aborted: return .deviceUnavailable
        case .unsupported: return .notSupported("device rejected the request")
        default: return .ioFailure(h.localizedDescription)
        }
    }
}

extension Duration {
    var nanoseconds: Int64 {
        let c = components
        return c.seconds * 1_000_000_000 + c.attoseconds / 1_000_000_000
    }
}
