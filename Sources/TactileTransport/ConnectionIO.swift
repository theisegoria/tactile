/// Internal dependency injection; deliberately not part of the public API or C ABI.
package struct ConnectionIO: Sendable {
    package var getFeature: @Sendable (UInt8) async throws(TransportError) -> [UInt8]
    package var send: @Sendable ([UInt8]) async throws(TransportError) -> Void
    package var close: @Sendable () async -> Void

    package init(
        getFeature: @escaping @Sendable (UInt8) async throws(TransportError) -> [UInt8] = {
            (_: UInt8) async throws(TransportError) -> [UInt8] in
            throw .notSupported("test feature")
        },
        send: @escaping @Sendable ([UInt8]) async throws(TransportError) -> Void,
        close: @escaping @Sendable () async -> Void = {}
    ) {
        self.getFeature = getFeature
        self.send = send
        self.close = close
    }
}
