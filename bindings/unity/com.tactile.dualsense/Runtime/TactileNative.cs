// P/Invoke declarations for tactile.h (C ABI 0.x). Layouts are pinned by
// Tests/CABI/header_check.c: tactile_input_state = 72 bytes, controller_info = 44.
using System;
using System.Runtime.InteropServices;

namespace Tactile
{
    public enum Result : int
    {
        Ok = 0, InvalidArgument = -1, NotConnected = -2, Permission = -3, IO = -4,
        Unsupported = -5, Timeout = -6, Busy = -7, Version = -8, NotFound = -9,
    }

    public enum TriggerSide : int { Left = 0, Right = 1 }
    public enum MuteLed : int { Off = 0, On = 1, Pulse = 2 }
    public enum HapticSide : int { Left = 0, Right = 1, Both = 2 }
    public enum HapticEffect : int { Click = 0, Detent = 1, Texture = 2, Impact = 3 }
    public enum ControllerEvent : int { Connected = 0, Reconnected = 1, Disconnected = 2 }
    public enum Permission : int { Granted = 0, Denied = 1, NotDetermined = 2 }

    [Flags]
    public enum Buttons : uint
    {
        None = 0,
        Square = 1u << 0, Cross = 1u << 1, Circle = 1u << 2, Triangle = 1u << 3,
        L1 = 1u << 4, R1 = 1u << 5, L2 = 1u << 6, R2 = 1u << 7,
        Create = 1u << 8, Options = 1u << 9, L3 = 1u << 10, R3 = 1u << 11,
        PS = 1u << 12, Touchpad = 1u << 13, Mute = 1u << 14,
        DpadUp = 1u << 15, DpadRight = 1u << 16, DpadDown = 1u << 17, DpadLeft = 1u << 18,
        FnLeft = 1u << 19, FnRight = 1u << 20, PaddleLeft = 1u << 21, PaddleRight = 1u << 22,
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NativeOptions
    {
        public uint struct_size;
        public int mode;
        public double max_output_reports_per_second;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct InputState
    {
        public uint struct_size;
        public byte left_x, left_y, right_x, right_y;
        public byte l2, r2;
        public byte has_imu, has_touch;
        public Buttons buttons;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public float[] gyro_dps;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public float[] accel_g;
        public uint sensor_timestamp;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2)] public byte[] touch_active;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2)] public byte[] touch_id;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2)] public ushort[] touch_x;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2)] public ushort[] touch_y;
        public int battery_percent;
        public int battery_charging;
        public ulong report_count;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ControllerInfo
    {
        public uint struct_size;
        public int model;      // 0 DualSense, 1 Edge
        public int transport;  // 0 Bluetooth, 1 USB
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 18)] public byte[] address;
        public uint firmware_version;
        public uint hardware_version;
        public ushort update_version;
        public byte vibration_v2;
        public byte connected;

        public string Address
        {
            get
            {
                if (address == null) return "";
                int n = Array.IndexOf(address, (byte)0);
                return System.Text.Encoding.ASCII.GetString(address, 0, n < 0 ? address.Length : n);
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TriggerEffect
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 11)] public byte[] bytes;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void EventCallback(IntPtr userData, IntPtr controller, int evt);

    public static class Native
    {
        // Unity resolves this to CTactile.bundle / libCTactile.dylib in Plugins/macOS.
        const string Lib = "CTactile";
        public const int AbiMajor = 0;

        [DllImport(Lib)] public static extern uint tactile_abi_version();
        [DllImport(Lib)] public static extern IntPtr tactile_version_string();
        [DllImport(Lib)] public static extern IntPtr tactile_result_string(int result);
        [DllImport(Lib)] public static extern int tactile_permission_status();
        [DllImport(Lib)] public static extern int tactile_permission_request();

        [DllImport(Lib)] public static extern int tactile_context_create(ref NativeOptions options, out IntPtr context);
        [DllImport(Lib)] public static extern void tactile_context_destroy(IntPtr context);
        [DllImport(Lib)] public static extern void tactile_context_set_callback(IntPtr context, EventCallback callback, IntPtr userData);
        [DllImport(Lib)] public static extern int tactile_context_controller_count(IntPtr context);
        [DllImport(Lib)] public static extern int tactile_context_get_controller(IntPtr context, int index, out IntPtr controller);
        [DllImport(Lib)] public static extern int tactile_context_wait_for_controller(IntPtr context, int timeoutMs, out IntPtr controller);

        [DllImport(Lib)] public static extern void tactile_controller_retain(IntPtr controller);
        [DllImport(Lib)] public static extern void tactile_controller_release(IntPtr controller);
        [DllImport(Lib)] public static extern int tactile_controller_get_info(IntPtr controller, ref ControllerInfo info);
        [DllImport(Lib)] public static extern int tactile_controller_get_input(IntPtr controller, ref InputState state);
        [DllImport(Lib)] public static extern int tactile_controller_set_lightbar(IntPtr controller, byte r, byte g, byte b);
        [DllImport(Lib)] public static extern int tactile_controller_set_player_leds(IntPtr controller, byte mask);
        [DllImport(Lib)] public static extern int tactile_controller_set_mute_led(IntPtr controller, int mode);
        [DllImport(Lib)] public static extern int tactile_controller_set_rumble(IntPtr controller, byte left, byte right);
        [DllImport(Lib)] public static extern int tactile_controller_set_trigger(IntPtr controller, int side, ref TriggerEffect effect);
        [DllImport(Lib)] public static extern int tactile_controller_neutralize(IntPtr controller);
        [DllImport(Lib)] public static extern int tactile_controller_last_error(IntPtr controller);

        [DllImport(Lib)] public static extern void tactile_trigger_off(ref TriggerEffect e);
        [DllImport(Lib)] public static extern int tactile_trigger_feedback(int position, int strength, ref TriggerEffect e);
        [DllImport(Lib)] public static extern int tactile_trigger_weapon(int start, int end, int strength, ref TriggerEffect e);
        [DllImport(Lib)] public static extern int tactile_trigger_vibration(int position, int amplitude, int frequency, ref TriggerEffect e);
        [DllImport(Lib)] public static extern int tactile_trigger_slope_feedback(int startPosition, int endPosition, int startStrength, int endStrength, ref TriggerEffect e);
        [DllImport(Lib)] public static extern int tactile_trigger_multiple_position_feedback(int[] strengths, ref TriggerEffect e);
        [DllImport(Lib)] public static extern int tactile_trigger_multiple_position_vibration(int frequency, int[] amplitudes, ref TriggerEffect e);
        [DllImport(Lib)] public static extern int tactile_trigger_bow(int start, int end, int strength, int snapForce, ref TriggerEffect e);
        [DllImport(Lib)] public static extern int tactile_trigger_galloping(int start, int end, int firstFoot, int secondFoot, int frequency, ref TriggerEffect e);
        [DllImport(Lib)] public static extern int tactile_trigger_machine(int start, int end, int amplitudeA, int amplitudeB, int frequency, int period, ref TriggerEffect e);

        [DllImport(Lib)] public static extern int tactile_haptics_start(IntPtr controller);
        [DllImport(Lib)] public static extern int tactile_haptics_stop(IntPtr controller);
        [DllImport(Lib)] public static extern int tactile_haptics_play(IntPtr controller, int effect, float intensity, int side);
        [DllImport(Lib)] public static extern int tactile_haptics_write_pcm(IntPtr controller, float[] interleaved, int frames, int channels, double sampleRate);

        public static string ResultString(int r) => Marshal.PtrToStringAnsi(tactile_result_string(r));
    }
}
