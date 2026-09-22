"""Tactile Python demo: prints input, Cross = haptic click, Circle = toggle R2 weapon."""
import sys
import time

sys.path.insert(0, __file__.rsplit("/examples/", 1)[0])
import tactile as t  # noqa: E402

if t.permission_status() != t.PERMISSION_GRANTED:
    t.request_permission()

with t.Context() as ctx:
    try:
        pad = ctx.wait_for_controller(5)
    except t.TactileError as e:
        sys.exit(f"no controller: {e}")
    print(pad.info())
    weapon, off, on = t.TriggerEffect.weapon(3, 6, 8), t.TriggerEffect.off(), False
    prev = 0
    while True:
        s = pad.input()
        if s:
            pressed = s.buttons & ~prev
            prev = s.buttons
            if pressed & t.Button.CROSS:
                pad.play(t.HAPTIC_CLICK)
            if pressed & t.Button.CIRCLE:
                on = not on
                pad.set_trigger(t.TRIGGER_RIGHT, weapon if on else off)
            if pressed & t.Button.OPTIONS:
                break
            print(f"\rL{s.left_stick} R{s.right_stick} L2 {s.l2:3d} R2 {s.r2:3d} buttons {s.buttons:#08x}", end="")
        time.sleep(1 / 60)
