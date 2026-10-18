"""Hardware-free tests: ABI version, struct layouts, golden trigger bytes."""
import ctypes as C
import gc
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import tactile as t  # noqa: E402


class BindingTests(unittest.TestCase):
    def test_abi(self):
        lib = t.load_library()
        self.assertEqual(lib.tactile_abi_version() >> 16, t.ABI_VERSION_MAJOR)
        self.assertTrue(t.version())

    def test_layouts_match_header(self):
        # Pinned by Tests/CABI/header_check.c.
        self.assertEqual(C.sizeof(t._InputState), 72)
        self.assertEqual(t._InputState.buttons.offset, 12)
        self.assertEqual(t._InputState.gyro_dps.offset, 16)
        self.assertEqual(C.sizeof(t._ControllerInfo), 44)
        self.assertEqual(C.sizeof(t.TriggerEffect), 11)
        self.assertEqual(C.sizeof(t._HapticsMetrics), 72)
        self.assertEqual(t._HapticsMetrics.reports_sent.offset, 8)
        self.assertEqual(t._HapticsMetrics.wake_lateness_p99_us.offset, 32)
        self.assertEqual(t._HapticsMetrics.pump_cpu_percent.offset, 64)

    def test_metrics_annotated(self):
        lib = t.load_library()
        self.assertEqual(lib.tactile_haptics_get_metrics.argtypes[1], C.POINTER(t._HapticsMetrics))
        with self.assertRaises(t.TactileError) as cm:
            t.Controller(0).haptics_metrics()
        self.assertEqual(cm.exception.code, t.ERR_INVALID_ARGUMENT)

    def test_context_callback_swaps_keep_one_thunk(self):
        with t.Context() as ctx:
            thunk = ctx._thunk
            ctx.on_event(lambda c, e: None)
            ctx.on_event(lambda c, e: None)
            ctx.on_event(None)
            self.assertIs(ctx._thunk, thunk)
        self.assertFalse(ctx._finalizer.alive)
        ctx.close()  # idempotent

    def test_dropped_context_is_destroyed(self):
        ctx = t.Context()
        ctx.on_event(print)
        finalizer = ctx._finalizer
        del ctx
        gc.collect()
        self.assertFalse(finalizer.alive)

    def test_trigger_golden(self):
        self.assertEqual(t.TriggerEffect.weapon(2, 6, 8).hex(), "25 44 00 07 00 00 00 00 00 00 00")
        self.assertEqual(t.TriggerEffect.feedback(3, 5).hex(), "21 f8 03 00 48 92 24 00 00 00 00")
        self.assertEqual(t.TriggerEffect.machine(1, 9, 3, 7, 5, 3).hex(), "27 02 02 3b 05 03 00 00 00 00 00")
        self.assertEqual(t.TriggerEffect.off().hex(), "05 00 00 00 00 00 00 00 00 00 00")
        self.assertEqual(t.TriggerEffect.multiple_position_feedback([0, 0, 8, 6, 4, 3, 1, 1, 1, 1]).hex(),
                         "21 fc 03 c0 3b 01 00 00 00 00 00")

    def test_invalid_pcm_rejected_before_native_call(self):
        controller = t.Controller(0)
        for channels, rate, samples in [(0, 48000, []), (-1, 48000, []), (2, 48000, [0]), (1, float("nan"), []), (1, float("inf"), [])]:
            with self.assertRaises(ValueError):
                controller.write_pcm(samples, channels, rate)

    def test_integer_arguments_do_not_wrap(self):
        with self.assertRaises(ValueError):
            t.TriggerEffect.feedback(2**32 + 3, 5)
        with self.assertRaises(ValueError):
            t.TriggerEffect.multiple_position_feedback([2**32] * 10)
        with self.assertRaises(ValueError):
            t.Controller(0).set_lightbar(256, 0, 0)
        with self.assertRaises(ValueError):
            t.Controller(0).set_rumble(-1, 0)

    def test_invalid_raises(self):
        with self.assertRaises(t.TactileError) as cm:
            t.TriggerEffect.weapon(1, 6, 8)
        self.assertEqual(cm.exception.code, t.ERR_INVALID_ARGUMENT)

    def test_player_led_instant_bit_reaches_native_validation(self):
        # Bit 5 is a documented instant-transition option, not an LED index.
        with self.assertRaises(t.TactileError):
            t.Controller(0).set_player_leds(0x3f)
        with self.assertRaises(ValueError):
            t.Controller(0).set_player_leds(0x40)


class PlayerBindingTests(unittest.TestCase):
    def test_player_calls_present_and_reject_null(self):
        lib = t.load_library()
        self.assertGreaterEqual(lib.tactile_abi_version() & 0xFFFF, t.ABI_VERSION_MINOR_PLAYERS)
        self.assertEqual(lib.tactile_controller_get_player(None), t.ERR_INVALID_ARGUMENT)
        self.assertEqual(lib.tactile_context_release_player(None, 1), t.ERR_INVALID_ARGUMENT)
        self.assertEqual(t.EVENT_PLAYER_CHANGED, 3)


if __name__ == "__main__":
    unittest.main()
