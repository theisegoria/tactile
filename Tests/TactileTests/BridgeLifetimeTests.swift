import Foundation
import Synchronization
import Testing
@testable import TactileBridge

@Suite struct BridgeLifetimeTests {
    @Test func releasingObservationRemovesNotificationCallback() {
        let center = NotificationCenter()
        let name = Notification.Name("TactileBridgeLifetimeTest")
        let deliveries = Mutex(0)
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            deliveries.withLock { $0 += 1 }
        }
        var observation: NotificationObservation? = NotificationObservation(token, center: center)
        #expect(observation != nil)
        center.post(name: name, object: nil)
        #expect(deliveries.withLock { $0 } == 1)
        observation = nil
        center.post(name: name, object: nil)
        #expect(deliveries.withLock { $0 } == 1)
    }
}
