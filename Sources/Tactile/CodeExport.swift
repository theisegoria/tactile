// Ready-to-paste snippets for trigger effects, haptic patterns and profiles,
// written against the exact public APIs of the Swift package and the
// bindings in bindings/ (C tactile.h, Unity C#, Unreal C++, Godot GDScript).

public import TactileCore

/// A target language for `TactileCodeExport`.
public enum CodeLanguage: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case swift
    case c
    case unityCSharp
    case unrealCpp
    case godotGDScript

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .swift: "Swift (Tactile)"
        case .c: "C (tactile.h)"
        case .unityCSharp: "Unity C#"
        case .unrealCpp: "Unreal C++"
        case .godotGDScript: "Godot GDScript"
        }
    }

    /// File extension for saving a snippet.
    public var fileExtension: String {
        switch self {
        case .swift: "swift"
        case .c: "c"
        case .unityCSharp: "cs"
        case .unrealCpp: "cpp"
        case .godotGDScript: "gd"
        }
    }

    var commentPrefix: String { self == .godotGDScript ? "#" : "//" }
}

/// Snippet generator. Every snippet assumes a variable for the controller:
/// Swift `controller` (`Controller`), C `controller` (`tactile_controller *`),
/// Unity `controller` (`TactileController`), Unreal `Tactile`
/// (`UTactileSubsystem*`, declared in the snippet), Godot `pad` (`TactilePad`).
public enum TactileCodeExport {
    // MARK: Triggers

    /// Builds `spec` and applies it to `side`. An invalid spec produces a
    /// comment saying so instead of code that would fail at run time.
    public static func trigger(_ spec: TriggerEffectSpec, side: TriggerSide, language: CodeLanguage) -> String {
        do {
            _ = try spec.effect()
        } catch {
            return "\(language.commentPrefix) Invalid trigger parameters (\(spec.typeName)): \(error)\n"
        }
        switch language {
        case .swift: return swiftTrigger(spec, side)
        case .c: return cTrigger(spec, side)
        case .unityCSharp: return unityTrigger(spec, side)
        case .unrealCpp: return unrealTrigger(spec, side)
        case .godotGDScript: return godotTrigger(spec, side)
        }
    }

    /// Applies a named preset through each API's preset call.
    public static func trigger(_ preset: TriggerPreset, side: TriggerSide, language: CodeLanguage) -> String {
        switch language {
        case .swift:
            return "try await controller.setTrigger(.\(side.rawValue), TriggerPreset.\(preset.rawValue).effect)\n"
        case .c:
            return """
            tactile_trigger_effect effect;
            tactile_trigger_from_preset(\(cPreset(preset)), &effect);
            tactile_controller_set_trigger(controller, \(cSide(side)), &effect);

            """
        case .unityCSharp:
            return "controller.SetTrigger(TriggerSide.\(pascal(side)), Triggers.Preset(TriggerPreset.\(pascalPreset(preset))));\n"
        case .unrealCpp:
            return """
            UTactileSubsystem* Tactile = GetGameInstance()->GetSubsystem<UTactileSubsystem>();
            Tactile->SetTrigger(ETactileTriggerSide::\(pascal(side)), UTactileSubsystem::TriggerPreset(ETactileTriggerPreset::\(pascalPreset(preset))));

            """
        case .godotGDScript:
            return "pad.set_trigger(TactilePad.\(cSide(side)), TactilePad.trigger_preset(TactilePad.\(godotPreset(preset))))\n"
        }
    }

    // MARK: Patterns and profiles

    /// Loads a `.tactilepattern` file and plays it. `path` is used as written:
    /// relative to the working directory (Swift, C), StreamingAssets (Unity),
    /// Content (Unreal) or `res://` (Godot).
    public static func pattern(path: String, language: CodeLanguage) -> String {
        switch language {
        case .swift:
            return """
            let player = try await controller.startPattern(contentsOf: URL(fileURLWithPath: \(quoted(path))))

            """
        case .c:
            return """
            tactile_pattern *pattern = NULL;
            if (tactile_pattern_load_file(\(quoted(path)), &pattern) == TACTILE_OK) {
                tactile_pattern_play(controller, pattern);
                tactile_pattern_free(pattern); /* playback keeps its own reference */
            }

            """
        case .unityCSharp:
            return """
            using (var pattern = TactilePattern.Load(System.IO.Path.Combine(Application.streamingAssetsPath, \(quoted(path)))))
                controller.PlayPattern(pattern);

            """
        case .unrealCpp:
            return """
            UTactileSubsystem* Tactile = GetGameInstance()->GetSubsystem<UTactileSubsystem>();
            Tactile->PlayPatternFile(TEXT(\(quoted(path))));

            """
        case .godotGDScript:
            return "pad.play_pattern_file(\(quoted(godotPath(path))))\n"
        }
    }

    /// Applies a `.tactileprofile` file (paths as for `pattern(path:language:)`).
    public static func profile(path: String, language: CodeLanguage) -> String {
        switch language {
        case .swift:
            return """
            let profile = try ControllerProfile(data: Data(contentsOf: URL(fileURLWithPath: \(quoted(path)))))
            try await controller.apply(profile)

            """
        case .c:
            return "tactile_profile_apply_file(controller, \(quoted(path)));\n"
        case .unityCSharp:
            return "controller.ApplyProfile(System.IO.Path.Combine(Application.streamingAssetsPath, \(quoted(path))));\n"
        case .unrealCpp:
            return """
            UTactileSubsystem* Tactile = GetGameInstance()->GetSubsystem<UTactileSubsystem>();
            Tactile->ApplyProfileFile(TEXT(\(quoted(path))));

            """
        case .godotGDScript:
            return "pad.apply_profile_file(\(quoted(godotPath(path))))\n"
        }
    }

    // MARK: Swift

    private static func swiftTrigger(_ spec: TriggerEffectSpec, _ side: TriggerSide) -> String {
        let expr: String
        switch spec {
        case .off: expr = "TriggerEffect.off"
        case let .feedback(p, s): expr = "try TriggerEffect.feedback(position: \(p), strength: \(s))"
        case let .multiplePositionFeedback(s): expr = "try TriggerEffect.multiplePositionFeedback(strengths: \(list(s)))"
        case let .slopeFeedback(sp, ep, ss, es):
            expr = "try TriggerEffect.slopeFeedback(startPosition: \(sp), endPosition: \(ep), startStrength: \(ss), endStrength: \(es))"
        case let .weapon(s, e, st): expr = "try TriggerEffect.weapon(start: \(s), end: \(e), strength: \(st))"
        case let .vibration(p, a, f): expr = "try TriggerEffect.vibration(position: \(p), amplitude: \(a), frequency: \(f))"
        case let .multiplePositionVibration(f, a):
            expr = "try TriggerEffect.multiplePositionVibration(frequency: \(f), amplitudes: \(list(a)))"
        case let .bow(s, e, st, sn): expr = "try TriggerEffect.bow(start: \(s), end: \(e), strength: \(st), snapForce: \(sn))"
        case let .galloping(s, e, f1, f2, f):
            expr = "try TriggerEffect.galloping(start: \(s), end: \(e), firstFoot: \(f1), secondFoot: \(f2), frequency: \(f))"
        case let .machine(s, e, a, b, f, p):
            expr = "try TriggerEffect.machine(start: \(s), end: \(e), amplitudeA: \(a), amplitudeB: \(b), frequency: \(f), period: \(p))"
        case let .raw(b): expr = "TriggerEffect(rawBytes: \(hexList(b, open: "[", close: "]")))"
        }
        return """
        let effect = \(expr)
        try await controller.setTrigger(.\(side.rawValue), effect)

        """
    }

    // MARK: C

    private static func cTrigger(_ spec: TriggerEffectSpec, _ side: TriggerSide) -> String {
        var lines: [String] = []
        switch spec {
        case .off:
            lines = ["tactile_trigger_effect effect;", "tactile_trigger_off(&effect);"]
        case let .feedback(p, s):
            lines = ["tactile_trigger_effect effect;", "tactile_trigger_feedback(\(p), \(s), &effect);"]
        case let .multiplePositionFeedback(s):
            lines = ["const int32_t strengths[10] = \(list(s, open: "{", close: "}"));", "tactile_trigger_effect effect;",
                     "tactile_trigger_multiple_position_feedback(strengths, &effect);"]
        case let .slopeFeedback(sp, ep, ss, es):
            lines = ["tactile_trigger_effect effect;", "tactile_trigger_slope_feedback(\(sp), \(ep), \(ss), \(es), &effect);"]
        case let .weapon(s, e, st):
            lines = ["tactile_trigger_effect effect;", "tactile_trigger_weapon(\(s), \(e), \(st), &effect);"]
        case let .vibration(p, a, f):
            lines = ["tactile_trigger_effect effect;", "tactile_trigger_vibration(\(p), \(a), \(f), &effect);"]
        case let .multiplePositionVibration(f, a):
            lines = ["const int32_t amplitudes[10] = \(list(a, open: "{", close: "}"));", "tactile_trigger_effect effect;",
                     "tactile_trigger_multiple_position_vibration(\(f), amplitudes, &effect);"]
        case let .bow(s, e, st, sn):
            lines = ["tactile_trigger_effect effect;", "tactile_trigger_bow(\(s), \(e), \(st), \(sn), &effect); /* unofficial */"]
        case let .galloping(s, e, f1, f2, f):
            lines = ["tactile_trigger_effect effect;", "tactile_trigger_galloping(\(s), \(e), \(f1), \(f2), \(f), &effect); /* unofficial */"]
        case let .machine(s, e, a, b, f, p):
            lines = ["tactile_trigger_effect effect;", "tactile_trigger_machine(\(s), \(e), \(a), \(b), \(f), \(p), &effect); /* unofficial */"]
        case let .raw(b):
            lines = ["tactile_trigger_effect effect = {\(hexList(b, open: "{", close: "}"))};"]
        }
        lines.append("tactile_controller_set_trigger(controller, \(cSide(side)), &effect);")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Unity

    private static func unityTrigger(_ spec: TriggerEffectSpec, _ side: TriggerSide) -> String {
        let expr: String
        switch spec {
        case .off: expr = "Triggers.Off()"
        case let .feedback(p, s): expr = "Triggers.Feedback(\(p), \(s))"
        case let .multiplePositionFeedback(s): expr = "Triggers.MultiplePositionFeedback(new[] \(list(s, open: "{ ", close: " }")))"
        case let .slopeFeedback(sp, ep, ss, es): expr = "Triggers.SlopeFeedback(\(sp), \(ep), \(ss), \(es))"
        case let .weapon(s, e, st): expr = "Triggers.Weapon(\(s), \(e), \(st))"
        case let .vibration(p, a, f): expr = "Triggers.Vibration(\(p), \(a), \(f))"
        case let .multiplePositionVibration(f, a):
            expr = "Triggers.MultiplePositionVibration(\(f), new[] \(list(a, open: "{ ", close: " }")))"
        case let .bow(s, e, st, sn): expr = "Triggers.Bow(\(s), \(e), \(st), \(sn))"
        case let .galloping(s, e, f1, f2, f): expr = "Triggers.Galloping(\(s), \(e), \(f1), \(f2), \(f))"
        case let .machine(s, e, a, b, f, p): expr = "Triggers.Machine(\(s), \(e), \(a), \(b), \(f), \(p))"
        case let .raw(b): expr = "new TriggerEffect { bytes = new byte[] \(hexList(b, open: "{ ", close: " }")) }"
        }
        return """
        var effect = \(expr);
        controller.SetTrigger(TriggerSide.\(pascal(side)), effect);

        """
    }

    // MARK: Unreal

    private static func unrealTrigger(_ spec: TriggerEffectSpec, _ side: TriggerSide) -> String {
        var effect: String
        switch spec {
        case .off: effect = "const FTactileTriggerEffect Effect = UTactileSubsystem::TriggerOff();"
        case let .feedback(p, s): effect = "const FTactileTriggerEffect Effect = UTactileSubsystem::TriggerFeedback(\(p), \(s));"
        case let .slopeFeedback(sp, ep, ss, es):
            effect = "const FTactileTriggerEffect Effect = UTactileSubsystem::TriggerSlopeFeedback(\(sp), \(ep), \(ss), \(es));"
        case let .weapon(s, e, st): effect = "const FTactileTriggerEffect Effect = UTactileSubsystem::TriggerWeapon(\(s), \(e), \(st));"
        case let .vibration(p, a, f): effect = "const FTactileTriggerEffect Effect = UTactileSubsystem::TriggerVibration(\(p), \(a), \(f));"
        case let .bow(s, e, st, sn): effect = "const FTactileTriggerEffect Effect = UTactileSubsystem::TriggerBow(\(s), \(e), \(st), \(sn));"
        case let .galloping(s, e, f1, f2, f):
            effect = "const FTactileTriggerEffect Effect = UTactileSubsystem::TriggerGalloping(\(s), \(e), \(f1), \(f2), \(f));"
        case let .machine(s, e, a, b, f, p):
            effect = "const FTactileTriggerEffect Effect = UTactileSubsystem::TriggerMachine(\(s), \(e), \(a), \(b), \(f), \(p));"
        case .multiplePositionFeedback, .multiplePositionVibration, .raw:
            // The plugin has no builder for these: pass the wire bytes.
            let bytes = (try? spec.effect().bytes) ?? []
            effect = "// \(spec.typeName): the plugin has no builder for it, so this passes the 11 wire bytes.\n"
                + "FTactileTriggerEffect Effect;\nEffect.Bytes = \(hexList(bytes, open: "{ ", close: " }"));"
        }
        return """
        UTactileSubsystem* Tactile = GetGameInstance()->GetSubsystem<UTactileSubsystem>();
        \(effect)
        Tactile->SetTrigger(ETactileTriggerSide::\(pascal(side)), Effect);

        """
    }

    // MARK: Godot

    private static func godotTrigger(_ spec: TriggerEffectSpec, _ side: TriggerSide) -> String {
        var pre = ""
        let expr: String
        switch spec {
        case .off: expr = "TactilePad.trigger_off()"
        case let .feedback(p, s): expr = "TactilePad.trigger_feedback(\(p), \(s))"
        case let .slopeFeedback(sp, ep, ss, es): expr = "TactilePad.trigger_slope_feedback(\(sp), \(ep), \(ss), \(es))"
        case let .weapon(s, e, st): expr = "TactilePad.trigger_weapon(\(s), \(e), \(st))"
        case let .vibration(p, a, f): expr = "TactilePad.trigger_vibration(\(p), \(a), \(f))"
        case let .bow(s, e, st, sn): expr = "TactilePad.trigger_bow(\(s), \(e), \(st), \(sn))"
        case let .galloping(s, e, f1, f2, f): expr = "TactilePad.trigger_galloping(\(s), \(e), \(f1), \(f2), \(f))"
        case let .machine(s, e, a, b, f, p): expr = "TactilePad.trigger_machine(\(s), \(e), \(a), \(b), \(f), \(p))"
        case .multiplePositionFeedback, .multiplePositionVibration, .raw:
            let bytes = (try? spec.effect().bytes) ?? []
            pre = "# \(spec.typeName): TactilePad has no builder for it, so this passes the 11 wire bytes.\n"
            expr = "PackedByteArray(\(hexList(bytes, open: "[", close: "]")))"
        }
        return """
        \(pre)var effect := \(expr)
        pad.set_trigger(TactilePad.\(cSide(side)), effect)

        """
    }

    // MARK: Helpers

    private static func cSide(_ side: TriggerSide) -> String {
        side == .left ? "TACTILE_TRIGGER_LEFT" : "TACTILE_TRIGGER_RIGHT"
    }

    private static func pascal(_ side: TriggerSide) -> String { side == .left ? "Left" : "Right" }

    private static func pascalPreset(_ p: TriggerPreset) -> String {
        switch p {
        case .off: "Off"
        case .weaponTrigger: "Weapon"
        case .bowDraw: "Bow"
        case .brakePedal: "Brake"
        case .clickDetent: "Click"
        case .machineGun: "MachineGun"
        case .gallop: "Gallop"
        }
    }

    private static func cPreset(_ p: TriggerPreset) -> String { "TACTILE_TRIGGER_PRESET_" + godotPresetSuffix(p) }
    private static func godotPreset(_ p: TriggerPreset) -> String { "TRIGGER_PRESET_" + godotPresetSuffix(p) }

    private static func godotPresetSuffix(_ p: TriggerPreset) -> String {
        switch p {
        case .off: "OFF"
        case .weaponTrigger: "WEAPON"
        case .bowDraw: "BOW"
        case .brakePedal: "BRAKE"
        case .clickDetent: "CLICK"
        case .machineGun: "MACHINE_GUN"
        case .gallop: "GALLOP"
        }
    }

    private static func list(_ v: [Int], open: String = "[", close: String = "]") -> String {
        open + v.map(String.init).joined(separator: ", ") + close
    }

    private static func hexList(_ b: [UInt8], open: String, close: String) -> String {
        let padded = TriggerEffect(rawBytes: b).bytes
        return open + padded.map { "0x" + (($0 < 16) ? "0" : "") + String($0, radix: 16) }.joined(separator: ", ") + close
    }

    /// A double-quoted string literal (valid in Swift, C, C#, C++ and GDScript).
    private static func quoted(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    private static func godotPath(_ path: String) -> String {
        path.hasPrefix("res://") || path.hasPrefix("user://") || path.hasPrefix("/") ? path : "res://" + path
    }
}
