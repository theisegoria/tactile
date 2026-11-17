import Testing
import TactileCore
@testable import Tactile

/// Golden snippets: each must use the exact public API of its binding
/// (bindings/ and Sources/CTactileHeaders/include/tactile.h).
@Suite struct CodeExportTests {
    let weapon = TriggerEffectSpec.weapon(start: 2, end: 6, strength: 8)
    let multi = TriggerEffectSpec.multiplePositionFeedback(strengths: [0, 0, 0, 5, 5, 5, 5, 5, 5, 5])

    @Test func weaponInEveryLanguage() {
        #expect(TactileCodeExport.trigger(weapon, side: .right, language: .swift) == """
        let effect = try TriggerEffect.weapon(start: 2, end: 6, strength: 8)
        try await controller.setTrigger(.right, effect)

        """)
        #expect(TactileCodeExport.trigger(weapon, side: .right, language: .c) == """
        tactile_trigger_effect effect;
        tactile_trigger_weapon(2, 6, 8, &effect);
        tactile_controller_set_trigger(controller, TACTILE_TRIGGER_RIGHT, &effect);

        """)
        #expect(TactileCodeExport.trigger(weapon, side: .right, language: .unityCSharp) == """
        var effect = Triggers.Weapon(2, 6, 8);
        controller.SetTrigger(TriggerSide.Right, effect);

        """)
        #expect(TactileCodeExport.trigger(weapon, side: .right, language: .unrealCpp) == """
        UTactileSubsystem* Tactile = GetGameInstance()->GetSubsystem<UTactileSubsystem>();
        const FTactileTriggerEffect Effect = UTactileSubsystem::TriggerWeapon(2, 6, 8);
        Tactile->SetTrigger(ETactileTriggerSide::Right, Effect);

        """)
        #expect(TactileCodeExport.trigger(weapon, side: .right, language: .godotGDScript) == """
        var effect := TactilePad.trigger_weapon(2, 6, 8)
        pad.set_trigger(TactilePad.TACTILE_TRIGGER_RIGHT, effect)

        """)
    }

    @Test func multiplePositionFeedback() {
        #expect(TactileCodeExport.trigger(multi, side: .left, language: .swift) == """
        let effect = try TriggerEffect.multiplePositionFeedback(strengths: [0, 0, 0, 5, 5, 5, 5, 5, 5, 5])
        try await controller.setTrigger(.left, effect)

        """)
        #expect(TactileCodeExport.trigger(multi, side: .left, language: .c) == """
        const int32_t strengths[10] = {0, 0, 0, 5, 5, 5, 5, 5, 5, 5};
        tactile_trigger_effect effect;
        tactile_trigger_multiple_position_feedback(strengths, &effect);
        tactile_controller_set_trigger(controller, TACTILE_TRIGGER_LEFT, &effect);

        """)
        #expect(TactileCodeExport.trigger(multi, side: .left, language: .unityCSharp) == """
        var effect = Triggers.MultiplePositionFeedback(new[] { 0, 0, 0, 5, 5, 5, 5, 5, 5, 5 });
        controller.SetTrigger(TriggerSide.Left, effect);

        """)
        // No builder in Unreal or Godot: the wire bytes (same vector as TriggerEffectTests.feedback).
        #expect(TactileCodeExport.trigger(multi, side: .left, language: .unrealCpp) == """
        UTactileSubsystem* Tactile = GetGameInstance()->GetSubsystem<UTactileSubsystem>();
        // multiplePositionFeedback: the plugin has no builder for it, so this passes the 11 wire bytes.
        FTactileTriggerEffect Effect;
        Effect.Bytes = { 0x21, 0xf8, 0x03, 0x00, 0x48, 0x92, 0x24, 0x00, 0x00, 0x00, 0x00 };
        Tactile->SetTrigger(ETactileTriggerSide::Left, Effect);

        """)
        #expect(TactileCodeExport.trigger(multi, side: .left, language: .godotGDScript) == """
        # multiplePositionFeedback: TactilePad has no builder for it, so this passes the 11 wire bytes.
        var effect := PackedByteArray([0x21, 0xf8, 0x03, 0x00, 0x48, 0x92, 0x24, 0x00, 0x00, 0x00, 0x00])
        pad.set_trigger(TactilePad.TACTILE_TRIGGER_LEFT, effect)

        """)
    }

    @Test func offRawAndUnofficial() {
        #expect(TactileCodeExport.trigger(TriggerEffectSpec.off, side: .left, language: .swift) == """
        let effect = TriggerEffect.off
        try await controller.setTrigger(.left, effect)

        """)
        #expect(TactileCodeExport.trigger(TriggerEffectSpec.off, side: .left, language: .c) == """
        tactile_trigger_effect effect;
        tactile_trigger_off(&effect);
        tactile_controller_set_trigger(controller, TACTILE_TRIGGER_LEFT, &effect);

        """)
        #expect(TactileCodeExport.trigger(.raw(bytes: [0x25, 0x44]), side: .right, language: .c) == """
        tactile_trigger_effect effect = {{0x25, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}};
        tactile_controller_set_trigger(controller, TACTILE_TRIGGER_RIGHT, &effect);

        """)
        #expect(TactileCodeExport.trigger(.raw(bytes: [0x25]), side: .right, language: .unityCSharp) == """
        var effect = new TriggerEffect { bytes = new byte[] { 0x25, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } };
        controller.SetTrigger(TriggerSide.Right, effect);

        """)
        let machine = TriggerPreset.machineGun.spec
        #expect(TactileCodeExport.trigger(machine, side: .right, language: .c).contains(
            "tactile_trigger_machine(1, 9, 7, 3, 9, 2, &effect); /* unofficial */"))
        #expect(TactileCodeExport.trigger(machine, side: .right, language: .godotGDScript).hasPrefix(
            "var effect := TactilePad.trigger_machine(1, 9, 7, 3, 9, 2)\n"))
        #expect(TactileCodeExport.trigger(TriggerPreset.gallop.spec, side: .left, language: .swift).hasPrefix(
            "let effect = try TriggerEffect.galloping(start: 0, end: 9, firstFoot: 2, secondFoot: 5, frequency: 3)\n"))
        #expect(TactileCodeExport.trigger(TriggerPreset.brakePedal.spec, side: .left, language: .unrealCpp).contains(
            "UTactileSubsystem::TriggerSlopeFeedback(0, 9, 1, 8);"))
        #expect(TactileCodeExport.trigger(.multiplePositionVibration(frequency: 30, amplitudes: [8, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
                                          side: .right, language: .unityCSharp).hasPrefix(
            "var effect = Triggers.MultiplePositionVibration(30, new[] { 8, 0, 0, 0, 0, 0, 0, 0, 0, 0 });\n"))
    }

    @Test func invalidSpecBecomesAComment() {
        let s = TactileCodeExport.trigger(.weapon(start: 1, end: 6, strength: 8), side: .right, language: .godotGDScript)
        #expect(s.hasPrefix("# Invalid trigger parameters (weapon): "))
        #expect(TactileCodeExport.trigger(.weapon(start: 1, end: 6, strength: 8), side: .right, language: .c).hasPrefix("// Invalid"))
    }

    @Test func presets() {
        #expect(TactileCodeExport.trigger(.weaponTrigger, side: .right, language: .swift)
            == "try await controller.setTrigger(.right, TriggerPreset.weaponTrigger.effect)\n")
        #expect(TactileCodeExport.trigger(.machineGun, side: .left, language: .c) == """
        tactile_trigger_effect effect;
        tactile_trigger_from_preset(TACTILE_TRIGGER_PRESET_MACHINE_GUN, &effect);
        tactile_controller_set_trigger(controller, TACTILE_TRIGGER_LEFT, &effect);

        """)
        #expect(TactileCodeExport.trigger(.brakePedal, side: .left, language: .unityCSharp)
            == "controller.SetTrigger(TriggerSide.Left, Triggers.Preset(TriggerPreset.Brake));\n")
        #expect(TactileCodeExport.trigger(.bowDraw, side: .right, language: .unrealCpp) == """
        UTactileSubsystem* Tactile = GetGameInstance()->GetSubsystem<UTactileSubsystem>();
        Tactile->SetTrigger(ETactileTriggerSide::Right, UTactileSubsystem::TriggerPreset(ETactileTriggerPreset::Bow));

        """)
        #expect(TactileCodeExport.trigger(.clickDetent, side: .right, language: .godotGDScript)
            == "pad.set_trigger(TactilePad.TACTILE_TRIGGER_RIGHT, TactilePad.trigger_preset(TactilePad.TRIGGER_PRESET_CLICK))\n")
    }

    @Test func patterns() {
        #expect(TactileCodeExport.pattern(path: "explosion.tactilepattern", language: .swift) == """
        let player = try await controller.startPattern(contentsOf: URL(fileURLWithPath: "explosion.tactilepattern"))

        """)
        #expect(TactileCodeExport.pattern(path: "explosion.tactilepattern", language: .c) == """
        tactile_pattern *pattern = NULL;
        if (tactile_pattern_load_file("explosion.tactilepattern", &pattern) == TACTILE_OK) {
            tactile_pattern_play(controller, pattern);
            tactile_pattern_free(pattern); /* playback keeps its own reference */
        }

        """)
        #expect(TactileCodeExport.pattern(path: "explosion.tactilepattern", language: .unityCSharp) == """
        using (var pattern = TactilePattern.Load(System.IO.Path.Combine(Application.streamingAssetsPath, "explosion.tactilepattern")))
            controller.PlayPattern(pattern);

        """)
        #expect(TactileCodeExport.pattern(path: "Haptics/explosion.tactilepattern", language: .unrealCpp) == """
        UTactileSubsystem* Tactile = GetGameInstance()->GetSubsystem<UTactileSubsystem>();
        Tactile->PlayPatternFile(TEXT("Haptics/explosion.tactilepattern"));

        """)
        #expect(TactileCodeExport.pattern(path: "haptics/explosion.tactilepattern", language: .godotGDScript)
            == "pad.play_pattern_file(\"res://haptics/explosion.tactilepattern\")\n")
        #expect(TactileCodeExport.pattern(path: "user://x.tactilepattern", language: .godotGDScript)
            == "pad.play_pattern_file(\"user://x.tactilepattern\")\n")
        // Quotes and backslashes are escaped.
        #expect(TactileCodeExport.pattern(path: #"a"b\c"#, language: .c).contains(#"tactile_pattern_load_file("a\"b\\c", &pattern)"#))
    }

    @Test func profiles() {
        #expect(TactileCodeExport.profile(path: "racing.tactileprofile", language: .c)
            == "tactile_profile_apply_file(controller, \"racing.tactileprofile\");\n")
        #expect(TactileCodeExport.profile(path: "racing.tactileprofile", language: .godotGDScript)
            == "pad.apply_profile_file(\"res://racing.tactileprofile\")\n")
        #expect(TactileCodeExport.profile(path: "racing.tactileprofile", language: .swift).contains("try await controller.apply(profile)"))
        #expect(TactileCodeExport.profile(path: "r", language: .unityCSharp)
            == "controller.ApplyProfile(System.IO.Path.Combine(Application.streamingAssetsPath, \"r\"));\n")
        #expect(TactileCodeExport.profile(path: "r", language: .unrealCpp).contains("Tactile->ApplyProfileFile(TEXT(\"r\"));"))
    }

    @Test func languageMetadata() {
        #expect(CodeLanguage.allCases.count == 5)
        #expect(CodeLanguage.godotGDScript.fileExtension == "gd")
        #expect(CodeLanguage.unityCSharp.displayName == "Unity C#")
    }
}
