"""Hardware-free tests: ABI version, struct layouts, golden trigger bytes."""
import ctypes as C
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

    def test_trigger_golden(self):
        self.assertEqual(t.TriggerEffect.weapon(2, 6, 8).hex(), "25 44 00 07 00 00 00 00 00 00 00")
        self.assertEqual(t.TriggerEffect.feedback(3, 5).hex(), "21 f8 03 00 48 92 24 00 00 00 00")
        self.assertEqual(t.TriggerEffect.machine(1, 9, 3, 7, 5, 3).hex(), "27 02 02 3b 05 03 00 00 00 00 00")
        self.assertEqual(t.TriggerEffect.off().hex(), "05 00 00 00 00 00 00 00 00 00 00")
        self.assertEqual(t.TriggerEffect.multiple_position_feedback([0, 0, 8, 6, 4, 3, 1, 1, 1, 1]).hex(),
                         "21 fc 03 c0 3b 01 00 00 00 00 00")

    def test_invalid_raises(self):
        with self.assertRaises(t.TactileError) as cm:
            t.TriggerEffect.weapon(1, 6, 8)
        self.assertEqual(cm.exception.code, t.ERR_INVALID_ARGUMENT)


if __name__ == "__main__":
    unittest.main()
