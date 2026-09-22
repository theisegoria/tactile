"""Python (ctypes) binding for the Tactile C ABI (tactile.h).

Loads libCTactile.dylib from $TACTILE_LIB, next to this package, or the SwiftPM
build directory. Mirrors the C ABI one-to-one plus a small Pythonic layer
(Context, Controller, InputState). Not affiliated with Sony Interactive Entertainment.
"""
from __future__ import annotations

import ctypes as C
import os
import pathlib
import threading
import weakref
from typing import Optional, Sequence

__all__ = [
    "ABI_VERSION_MAJOR", "TactileError", "Context", "Controller", "InputState", "ControllerInfo",
    "TriggerEffect", "Button", "HapticsMetrics", "load_library",
]

ABI_VERSION_MAJOR = 0

# ---- result codes and enums (tactile.h) ------------------------------------

OK = 0
ERR_INVALID_ARGUMENT, ERR_NOT_CONNECTED, ERR_PERMISSION, ERR_IO = -1, -2, -3, -4
ERR_UNSUPPORTED, ERR_TIMEOUT, ERR_BUSY, ERR_VERSION, ERR_NOT_FOUND = -5, -6, -7, -8, -9

MODE_SHARED, MODE_EXCLUSIVE = 0, 1
TRIGGER_LEFT, TRIGGER_RIGHT = 0, 1
MUTE_LED_OFF, MUTE_LED_ON, MUTE_LED_PULSE = 0, 1, 2
HAPTIC_LEFT, HAPTIC_RIGHT, HAPTIC_BOTH = 0, 1, 2
HAPTIC_CLICK, HAPTIC_DETENT, HAPTIC_TEXTURE, HAPTIC_IMPACT = 0, 1, 2, 3
EVENT_CONNECTED, EVENT_RECONNECTED, EVENT_DISCONNECTED = 0, 1, 2
PERMISSION_GRANTED, PERMISSION_DENIED, PERMISSION_NOT_DETERMINED = 0, 1, 2


class Button:
    SQUARE, CROSS, CIRCLE, TRIANGLE = 1 << 0, 1 << 1, 1 << 2, 1 << 3
    L1, R1, L2, R2 = 1 << 4, 1 << 5, 1 << 6, 1 << 7
    CREATE, OPTIONS, L3, R3 = 1 << 8, 1 << 9, 1 << 10, 1 << 11
    PS, TOUCHPAD, MUTE = 1 << 12, 1 << 13, 1 << 14
    DPAD_UP, DPAD_RIGHT, DPAD_DOWN, DPAD_LEFT = 1 << 15, 1 << 16, 1 << 17, 1 << 18
    FN_LEFT, FN_RIGHT, PADDLE_LEFT, PADDLE_RIGHT = 1 << 19, 1 << 20, 1 << 21, 1 << 22


# ---- structs (layout must match tactile.h; checked by tests) ---------------

class _Options(C.Structure):
    _fields_ = [("struct_size", C.c_uint32), ("mode", C.c_int32), ("max_output_reports_per_second", C.c_double)]


class _InputState(C.Structure):
    _fields_ = [
        ("struct_size", C.c_uint32),
        ("left_x", C.c_uint8), ("left_y", C.c_uint8), ("right_x", C.c_uint8), ("right_y", C.c_uint8),
        ("l2", C.c_uint8), ("r2", C.c_uint8), ("has_imu", C.c_uint8), ("has_touch", C.c_uint8),
        ("buttons", C.c_uint32),
        ("gyro_dps", C.c_float * 3), ("accel_g", C.c_float * 3),
        ("sensor_timestamp", C.c_uint32),
        ("touch_active", C.c_uint8 * 2), ("touch_id", C.c_uint8 * 2),
        ("touch_x", C.c_uint16 * 2), ("touch_y", C.c_uint16 * 2),
        ("battery_percent", C.c_int32), ("battery_charging", C.c_int32),
        ("report_count", C.c_uint64),
    ]


class _ControllerInfo(C.Structure):
    _fields_ = [
        ("struct_size", C.c_uint32), ("model", C.c_int32), ("transport", C.c_int32),
        ("address", C.c_char * 18),
        ("firmware_version", C.c_uint32), ("hardware_version", C.c_uint32),
        ("update_version", C.c_uint16), ("vibration_v2", C.c_uint8), ("connected", C.c_uint8),
    ]


class _HapticsMetrics(C.Structure):
    _fields_ = [
        ("struct_size", C.c_uint32),
        ("reports_sent", C.c_uint64), ("reports_dropped", C.c_uint64), ("underrun_ticks", C.c_uint64),
        ("wake_lateness_p99_us", C.c_double), ("tick_interval_stddev_us", C.c_double),
        ("send_latency_mean_us", C.c_double), ("send_latency_p99_us", C.c_double),
        ("pump_cpu_percent", C.c_double),
    ]


class TriggerEffect(C.Structure):
    """11-byte wire encoding of an adaptive-trigger effect. Build with the static methods."""
    _fields_ = [("bytes", C.c_uint8 * 11)]

    def hex(self) -> str:
        return " ".join(f"{b:02x}" for b in self.bytes)

    @staticmethod
    def off() -> "TriggerEffect":
        e = TriggerEffect(); _lib().tactile_trigger_off(C.byref(e)); return e

    @staticmethod
    def _build(fn, *args) -> "TriggerEffect":
        e = TriggerEffect()
        _check(fn(*[C.c_int32(a) for a in args], C.byref(e)))
        return e

    @staticmethod
    def feedback(position: int, strength: int) -> "TriggerEffect":
        return TriggerEffect._build(_lib().tactile_trigger_feedback, position, strength)

    @staticmethod
    def weapon(start: int, end: int, strength: int) -> "TriggerEffect":
        return TriggerEffect._build(_lib().tactile_trigger_weapon, start, end, strength)

    @staticmethod
    def vibration(position: int, amplitude: int, frequency: int) -> "TriggerEffect":
        return TriggerEffect._build(_lib().tactile_trigger_vibration, position, amplitude, frequency)

    @staticmethod
    def slope_feedback(start_position: int, end_position: int, start_strength: int, end_strength: int) -> "TriggerEffect":
        return TriggerEffect._build(_lib().tactile_trigger_slope_feedback, start_position, end_position, start_strength, end_strength)

    @staticmethod
    def multiple_position_feedback(strengths: Sequence[int]) -> "TriggerEffect":
        if len(strengths) != 10:
            raise ValueError("strengths needs 10 entries")
        e = TriggerEffect()
        _check(_lib().tactile_trigger_multiple_position_feedback((C.c_int32 * 10)(*strengths), C.byref(e)))
        return e

    @staticmethod
    def multiple_position_vibration(frequency: int, amplitudes: Sequence[int]) -> "TriggerEffect":
        if len(amplitudes) != 10:
            raise ValueError("amplitudes needs 10 entries")
        e = TriggerEffect()
        _check(_lib().tactile_trigger_multiple_position_vibration(C.c_int32(frequency), (C.c_int32 * 10)(*amplitudes), C.byref(e)))
        return e

    # Unofficial effects
    @staticmethod
    def bow(start: int, end: int, strength: int, snap_force: int) -> "TriggerEffect":
        return TriggerEffect._build(_lib().tactile_trigger_bow, start, end, strength, snap_force)

    @staticmethod
    def galloping(start: int, end: int, first_foot: int, second_foot: int, frequency: int) -> "TriggerEffect":
        return TriggerEffect._build(_lib().tactile_trigger_galloping, start, end, first_foot, second_foot, frequency)

    @staticmethod
    def machine(start: int, end: int, amplitude_a: int, amplitude_b: int, frequency: int, period: int) -> "TriggerEffect":
        return TriggerEffect._build(_lib().tactile_trigger_machine, start, end, amplitude_a, amplitude_b, frequency, period)


_EventCallback = C.CFUNCTYPE(None, C.c_void_p, C.c_void_p, C.c_int32)

# ---- library loading --------------------------------------------------------

_LIB: Optional[C.CDLL] = None


def _candidates():
    env = os.environ.get("TACTILE_LIB")
    if env:
        yield pathlib.Path(env)
    here = pathlib.Path(__file__).resolve().parent
    yield here / "libCTactile.dylib"
    root = here.parents[2]
    for cfg in ("Release", "Debug"):
        yield root / ".build" / "out" / "Products" / cfg / "libCTactile.dylib"
    for cfg in ("release", "debug"):
        yield root / ".build" / cfg / "libCTactile.dylib"


def load_library(path: Optional[str] = None) -> C.CDLL:
    """Loads and type-annotates libCTactile. Raises TactileError on ABI mismatch."""
    global _LIB
    if _LIB is not None and path is None:
        return _LIB
    paths = [pathlib.Path(path)] if path else list(_candidates())
    for p in paths:
        if p.exists():
            lib = C.CDLL(str(p))
            break
    else:
        raise OSError("libCTactile.dylib not found; build it with `swift build --product CTactile` or set TACTILE_LIB")
    _annotate(lib)
    abi = lib.tactile_abi_version()
    if abi >> 16 != ABI_VERSION_MAJOR:
        raise TactileError(ERR_VERSION, f"library ABI {abi >> 16}.{abi & 0xFFFF}, binding expects {ABI_VERSION_MAJOR}.x")
    _LIB = lib
    return lib


def _lib() -> C.CDLL:
    return _LIB if _LIB is not None else load_library()


def _annotate(lib: C.CDLL) -> None:
    i32, u8, vp, P = C.c_int32, C.c_uint8, C.c_void_p, C.POINTER
    sig = {
        "tactile_abi_version": (C.c_uint32, []),
        "tactile_version_string": (C.c_char_p, []),
        "tactile_result_string": (C.c_char_p, [i32]),
        "tactile_permission_status": (i32, []),
        "tactile_permission_request": (i32, []),
        "tactile_context_create": (i32, [P(_Options), P(vp)]),
        "tactile_context_destroy": (None, [vp]),
        "tactile_context_set_callback": (None, [vp, _EventCallback, vp]),
        "tactile_context_controller_count": (i32, [vp]),
        "tactile_context_get_controller": (i32, [vp, i32, P(vp)]),
        "tactile_context_wait_for_controller": (i32, [vp, i32, P(vp)]),
        "tactile_controller_retain": (None, [vp]),
        "tactile_controller_release": (None, [vp]),
        "tactile_controller_get_info": (i32, [vp, P(_ControllerInfo)]),
        "tactile_controller_get_input": (i32, [vp, P(_InputState)]),
        "tactile_controller_set_lightbar": (i32, [vp, u8, u8, u8]),
        "tactile_controller_set_player_leds": (i32, [vp, u8]),
        "tactile_controller_set_mute_led": (i32, [vp, i32]),
        "tactile_controller_set_rumble": (i32, [vp, u8, u8]),
        "tactile_controller_set_trigger": (i32, [vp, i32, P(TriggerEffect)]),
        "tactile_controller_neutralize": (i32, [vp]),
        "tactile_controller_last_error": (i32, [vp]),
        "tactile_trigger_off": (None, [P(TriggerEffect)]),
        "tactile_trigger_feedback": (i32, [i32, i32, P(TriggerEffect)]),
        "tactile_trigger_weapon": (i32, [i32, i32, i32, P(TriggerEffect)]),
        "tactile_trigger_vibration": (i32, [i32, i32, i32, P(TriggerEffect)]),
        "tactile_trigger_slope_feedback": (i32, [i32, i32, i32, i32, P(TriggerEffect)]),
        "tactile_trigger_multiple_position_feedback": (i32, [P(C.c_int32), P(TriggerEffect)]),
        "tactile_trigger_multiple_position_vibration": (i32, [i32, P(C.c_int32), P(TriggerEffect)]),
        "tactile_trigger_bow": (i32, [i32, i32, i32, i32, P(TriggerEffect)]),
        "tactile_trigger_galloping": (i32, [i32, i32, i32, i32, i32, P(TriggerEffect)]),
        "tactile_trigger_machine": (i32, [i32, i32, i32, i32, i32, i32, P(TriggerEffect)]),
        "tactile_haptics_start": (i32, [vp]),
        "tactile_haptics_stop": (i32, [vp]),
        "tactile_haptics_play": (i32, [vp, i32, C.c_float, i32]),
        "tactile_haptics_write_pcm": (i32, [vp, P(C.c_float), i32, i32, C.c_double]),
        "tactile_haptics_get_metrics": (i32, [vp, P(_HapticsMetrics)]),
    }
    for name, (res, args) in sig.items():
        fn = getattr(lib, name)
        fn.restype = res
        fn.argtypes = args


class TactileError(RuntimeError):
    def __init__(self, code: int, message: Optional[str] = None):
        self.code = code
        text = message or (_lib().tactile_result_string(code) or b"").decode()
        super().__init__(f"{text} ({code})")


def _check(code: int) -> int:
    if code < 0:
        raise TactileError(code)
    return code


def version() -> str:
    return _lib().tactile_version_string().decode()


def permission_status() -> int:
    return _lib().tactile_permission_status()


def request_permission() -> bool:
    return _lib().tactile_permission_request() == OK


# ---- Pythonic layer ---------------------------------------------------------

class InputState:
    __slots__ = ("left_stick", "right_stick", "l2", "r2", "buttons", "gyro_dps", "accel_g", "touches",
                 "battery_percent", "battery_charging", "report_count")

    def __init__(self, s: _InputState):
        self.left_stick = (s.left_x, s.left_y)
        self.right_stick = (s.right_x, s.right_y)
        self.l2, self.r2, self.buttons = s.l2, s.r2, s.buttons
        self.gyro_dps = tuple(s.gyro_dps) if s.has_imu else None
        self.accel_g = tuple(s.accel_g) if s.has_imu else None
        self.touches = [(s.touch_id[i], s.touch_x[i], s.touch_y[i]) for i in range(2) if s.has_touch and s.touch_active[i]]
        self.battery_percent = s.battery_percent if s.battery_percent >= 0 else None
        self.battery_charging = s.battery_charging
        self.report_count = s.report_count

    def pressed(self, button: int) -> bool:
        return bool(self.buttons & button)


class ControllerInfo:
    def __init__(self, i: _ControllerInfo):
        self.model = "DualSense Edge" if i.model == 1 else "DualSense"
        self.transport = "usb" if i.transport == 1 else "bluetooth"
        self.address = i.address.decode()
        self.firmware_version = i.firmware_version
        self.hardware_version = i.hardware_version
        self.update_version = f"{i.update_version >> 8}.{i.update_version & 0xFF:02d}"
        self.vibration_v2 = bool(i.vibration_v2)
        self.connected = bool(i.connected)

    def __repr__(self) -> str:
        return f"<ControllerInfo {self.model} {self.transport} {self.address or '?'} update {self.update_version}>"


class HapticsMetrics:
    """Haptics pump statistics (all zero while haptics are stopped)."""
    __slots__ = tuple(name for name, _ in _HapticsMetrics._fields_ if name != "struct_size")

    def __init__(self, m: _HapticsMetrics):
        for name in self.__slots__:
            setattr(self, name, getattr(m, name))

    def __repr__(self) -> str:
        return "<HapticsMetrics " + " ".join(f"{n}={getattr(self, n)}" for n in self.__slots__) + ">"


class Controller:
    """A retained controller handle. Output calls are non-blocking.

    Holds a reference to the Context it came from, so the native context (which
    the handle needs for output) stays alive while the Controller is in use.
    """

    def __init__(self, handle: int, context: Optional["Context"] = None):
        self._h = C.c_void_p(handle)
        self._context = context

    def close(self) -> None:
        if self._h:
            _lib().tactile_controller_release(self._h)
            self._h = C.c_void_p()
        self._context = None

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    def info(self) -> ControllerInfo:
        i = _ControllerInfo(); i.struct_size = C.sizeof(i)
        _check(_lib().tactile_controller_get_info(self._h, C.byref(i)))
        return ControllerInfo(i)

    def input(self) -> Optional[InputState]:
        s = _InputState(); s.struct_size = C.sizeof(s)
        r = _lib().tactile_controller_get_input(self._h, C.byref(s))
        if r == ERR_NOT_CONNECTED:
            return None
        _check(r)
        return InputState(s)

    def set_lightbar(self, r: int, g: int, b: int) -> None:
        _check(_lib().tactile_controller_set_lightbar(self._h, r, g, b))

    def set_player_leds(self, mask: int) -> None:
        _check(_lib().tactile_controller_set_player_leds(self._h, mask))

    def set_mute_led(self, mode: int) -> None:
        _check(_lib().tactile_controller_set_mute_led(self._h, mode))

    def set_rumble(self, left: int, right: int) -> None:
        _check(_lib().tactile_controller_set_rumble(self._h, left, right))

    def set_trigger(self, side: int, effect: TriggerEffect) -> None:
        _check(_lib().tactile_controller_set_trigger(self._h, side, C.byref(effect)))

    def neutralize(self) -> None:
        _check(_lib().tactile_controller_neutralize(self._h))

    def last_error(self) -> int:
        return _lib().tactile_controller_last_error(self._h)

    def haptics_start(self) -> None:
        _check(_lib().tactile_haptics_start(self._h))

    def haptics_stop(self) -> None:
        _check(_lib().tactile_haptics_stop(self._h))

    def play(self, effect: int = HAPTIC_CLICK, intensity: float = 1.0, side: int = HAPTIC_BOTH) -> None:
        _check(_lib().tactile_haptics_play(self._h, effect, intensity, side))

    def write_pcm(self, samples: Sequence[float], channels: int, sample_rate: float) -> int:
        n = len(samples)
        buf = (C.c_float * n)(*samples)
        return _check(_lib().tactile_haptics_write_pcm(self._h, buf, n // channels, channels, sample_rate))

    def haptics_metrics(self) -> HapticsMetrics:
        m = _HapticsMetrics(); m.struct_size = C.sizeof(m)
        _check(_lib().tactile_haptics_get_metrics(self._h, C.byref(m)))
        return HapticsMetrics(m)


# Set while an event callback runs on the library's callback thread, where
# tactile_context_destroy must not be called (it waits for that very callback).
_callback_thread = threading.local()


def _in_callback() -> bool:
    return getattr(_callback_thread, "active", False)


class _Dispatch:
    """State shared by a Context's single event trampoline. It holds no strong
    reference to the Context, so the trampoline never keeps it alive."""

    def __init__(self, context: "Context"):
        self.fn = None
        self.context = weakref.ref(context)


def _make_thunk(dispatch: _Dispatch):
    def trampoline(_user, handle, event):
        fn = dispatch.fn
        if fn is None or not handle:
            return
        _callback_thread.active = True
        try:
            _lib().tactile_controller_retain(handle)
            fn(Controller(handle, dispatch.context()), event)
        finally:
            _callback_thread.active = False

    return _EventCallback(trampoline)


def _destroy_native(handle: C.c_void_p, thunk) -> None:
    """Finalizer body. Keeps `thunk` referenced until destroy has returned:
    destroy drains queued callbacks, so only then can the closure be freed."""

    def destroy():
        _lib().tactile_context_destroy(handle)
        del thunk_ref[:]

    thunk_ref = [thunk]
    if _in_callback():
        # Dropped from inside a callback (destroy would wait for it forever):
        # tear down on another thread, which waits for the callback to return.
        threading.Thread(target=destroy, name="tactile-context-destroy", daemon=False).start()
    else:
        destroy()


class Context:
    """Discovery context. Use as a context manager; closing restores neutral output.

    A Context that is dropped without close() is still destroyed (neutralizing
    output) once it and every Controller obtained from it are garbage, or at
    interpreter exit.
    """

    def __init__(self, exclusive: bool = False, max_output_reports_per_second: float = 0):
        o = _Options(C.sizeof(_Options), MODE_EXCLUSIVE if exclusive else MODE_SHARED, max_output_reports_per_second)
        self._h = C.c_void_p()
        _check(_lib().tactile_context_create(C.byref(o), C.byref(self._h)))
        # One permanent C callback per context. on_event only swaps the Python
        # function it dispatches to, so no ctypes closure the library may still
        # call is ever freed before tactile_context_destroy has returned.
        self._dispatch = _Dispatch(self)
        self._thunk = _make_thunk(self._dispatch)
        self._installed = False
        self._finalizer = weakref.finalize(self, _destroy_native, self._h, self._thunk)

    def __enter__(self) -> "Context":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        """Neutralizes and closes every controller. Not callable from an event callback."""
        if not self._finalizer.alive:
            return
        if _in_callback():
            raise RuntimeError("Context.close() cannot be called from an event callback")
        self._dispatch.fn = None
        self._finalizer()
        self._h = C.c_void_p()

    def on_event(self, fn) -> None:
        """fn(controller: Controller, event: int) runs on a library thread; None removes it."""
        if not self._h:
            raise TactileError(ERR_INVALID_ARGUMENT, "context is closed")
        self._dispatch.fn = fn
        if fn is not None and not self._installed:
            _lib().tactile_context_set_callback(self._h, self._thunk, None)
            self._installed = True

    def controllers(self):
        out = []
        for i in range(_lib().tactile_context_controller_count(self._h)):
            h = C.c_void_p()
            if _lib().tactile_context_get_controller(self._h, i, C.byref(h)) == OK:
                out.append(Controller(h.value, self))
        return out

    def wait_for_controller(self, timeout: float = 5.0) -> Controller:
        h = C.c_void_p()
        _check(_lib().tactile_context_wait_for_controller(self._h, int(timeout * 1000), C.byref(h)))
        return Controller(h.value, self)
