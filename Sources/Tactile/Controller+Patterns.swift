// Haptic pattern playback on a controller.

public import Foundation
public import TactileCore
public import TactileHaptics
import TactileTransport

extension Controller: HapticPatternOutput {
    /// Pattern trigger change; failures (e.g. a disconnect) are ignored so the
    /// rest of the pattern keeps playing.
    public func patternSetTrigger(_ side: TriggerSide, _ effect: TriggerEffect) async {
        try? await setTrigger(side, effect)
    }

    public func patternSetLightbar(_ color: LightbarColor) async {
        try? await setLightbar(color)
    }
}

extension Controller {
    /// Starts haptics if needed and returns a player for `pattern`, already
    /// playing. Keep the player to stop it (`player.stop()`). Clips resolve relative to `clipBase` (the pattern file's
    /// folder when loaded from disk).
    @discardableResult
    public func startPattern(_ pattern: HapticPattern, clipBase: URL? = nil) async throws -> HapticPatternPlayer {
        let player = try HapticPatternPlayer(pattern: pattern, mixer: haptics, output: self,
                                             clipLoader: HapticPatternRenderer.fileClipLoader(relativeTo: clipBase))
        try await startHaptics()
        player.start()
        return player
    }

    /// Plays `pattern` to the end (cancel the calling task to stop it).
    public func play(_ pattern: HapticPattern, clipBase: URL? = nil) async throws {
        let player = try HapticPatternPlayer(pattern: pattern, mixer: haptics, output: self,
                                             clipLoader: HapticPatternRenderer.fileClipLoader(relativeTo: clipBase))
        try await startHaptics()
        await player.play()
    }

    /// Loads a `.tactilepattern` file and starts it (clips relative to the file).
    @discardableResult
    public func startPattern(contentsOf url: URL) async throws -> HapticPatternPlayer {
        try await startPattern(HapticPattern(contentsOf: url), clipBase: url.deletingLastPathComponent())
    }
}
