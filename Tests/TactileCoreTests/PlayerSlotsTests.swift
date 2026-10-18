import Testing
@testable import TactileCore

@Suite struct PlayerSlotsTests {
    @Test func joinInOrderAndRejectWhenFull() {
        var s = PlayerSlots(capacity: 2)
        #expect(s.connect("a") == [.joined(player: 1, id: "a")])
        #expect(s.connect("b") == [.joined(player: 2, id: "b")])
        #expect(s.connect("c") == [.rejected(id: "c")])
        #expect(s.connect("a") == [])  // already connected: no change
        #expect(s.activePlayers.map(\.id) == ["a", "b"])
    }

    @Test func disconnectHoldsSlotAndReconnectReturns() {
        var s = PlayerSlots(capacity: 4)
        _ = s.connect("a"); _ = s.connect("b"); _ = s.connect("c")
        #expect(s.disconnect("b") == [.left(player: 2, id: "b")])
        // A new controller does not take the held slot while free ones exist.
        #expect(s.connect("d") == [.joined(player: 4, id: "d")])
        #expect(s.connect("b") == [.rejoined(player: 2, id: "b")])
        #expect(s.disconnect("zz") == [])
    }

    @Test func fullTableReclaimsLowestHeldSlot() {
        var s = PlayerSlots(capacity: 2)
        _ = s.connect("a"); _ = s.connect("b")
        _ = s.disconnect("a")
        #expect(s.connect("c") == [.released(player: 1, id: "a"), .joined(player: 1, id: "c")])
        #expect(s.player(of: "a") == nil)
    }

    @Test func noHoldReleasesOnDisconnect() {
        var s = PlayerSlots(capacity: 4, holdDisconnected: false)
        _ = s.connect("a"); _ = s.connect("b")
        #expect(s.disconnect("a") == [.released(player: 1, id: "a")])
        #expect(s.connect("c") == [.joined(player: 1, id: "c")])
    }

    @Test func assignSwaps() {
        var s = PlayerSlots(capacity: 4)
        _ = s.connect("a"); _ = s.connect("b")
        #expect(s.assign("b", to: 1) == [.moved(from: 1, to: 2, id: "a"), .moved(from: 2, to: 1, id: "b")])
        #expect(s.player(of: "b") == 1 && s.player(of: "a") == 2)
        #expect(s.assign("b", to: 3) == [.moved(from: 1, to: 3, id: "b")])
        #expect(s.slot(1) == nil)
        #expect(s.assign("b", to: 3) == [])
        #expect(s.assign("b", to: 9) == [])
    }

    @Test func assignNewcomerDisplacesToFreeSlotOrReleases() {
        var s = PlayerSlots(capacity: 2)
        _ = s.connect("a")
        #expect(s.assign("x", to: 1) == [.joined(player: 1, id: "x"), .moved(from: 1, to: 2, id: "a")])
        #expect(s.assign("y", to: 2) == [.joined(player: 2, id: "y"), .released(player: 2, id: "a")])
    }

    @Test func releaseAndResize() {
        var s = PlayerSlots(capacity: 4)
        _ = s.connect("a"); _ = s.connect("b"); _ = s.connect("c")
        #expect(s.release(player: 2) == [.released(player: 2, id: "b")])
        #expect(s.release(player: 2) == [])
        #expect(s.resize(1) == [.released(player: 3, id: "c")])
        #expect(s.capacity == 1)
        #expect(s.resize(20).isEmpty && s.capacity == PlayerSlots.maxCapacity)
        #expect(PlayerSlots(capacity: 0).capacity == 1)
    }

    @Test func changeAccessors() {
        #expect(PlayerSlots.Change.moved(from: 1, to: 3, id: "q").player == 3)
        #expect(PlayerSlots.Change.released(player: 2, id: "q").player == nil)
        #expect(PlayerSlots.Change.rejected(id: "z").id == "z")
    }

    @Test func playerColours() {
        #expect(LightbarColor.player(1) == LightbarColor(red: 0, green: 64, blue: 255))
        #expect(LightbarColor.player(2) != LightbarColor.player(1))
        #expect(LightbarColor.player(5) == LightbarColor(red: 0, green: 21, blue: 85))
        #expect(LightbarColor.player(0) == .defaultBlue)
    }
}
