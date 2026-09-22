// Managed wrapper: a MonoBehaviour that owns the context, marshals lifecycle
// events to the main thread and exposes the first controller.
using System;
using System.Collections.Concurrent;
using UnityEngine;

namespace Tactile
{
    public sealed class TactileException : Exception
    {
        public readonly Result Code;
        public TactileException(int code) : base(Native.ResultString(code) + " (" + code + ")") { Code = (Result)code; }
        internal static int Check(int code) { if (code < 0) throw new TactileException(code); return code; }
    }

    /// <summary>A retained controller handle. All output calls are non-blocking.</summary>
    public sealed class TactileController : IDisposable
    {
        IntPtr handle;
        InputState state = NewState();
        internal TactileController(IntPtr retained) { handle = retained; }

        static InputState NewState() => new InputState { struct_size = 72 };

        public bool IsValid => handle != IntPtr.Zero;

        public ControllerInfo Info
        {
            get
            {
                var i = new ControllerInfo { struct_size = 44 };
                TactileException.Check(Native.tactile_controller_get_info(handle, ref i));
                return i;
            }
        }

        /// <summary>Copies the latest input. Returns false until the first report arrives.</summary>
        public bool TryGetInput(out InputState s)
        {
            int r = Native.tactile_controller_get_input(handle, ref state);
            s = state;
            if (r == (int)Result.NotConnected) return false;
            TactileException.Check(r);
            return true;
        }

        public void SetLightbar(Color32 c) => TactileException.Check(Native.tactile_controller_set_lightbar(handle, c.r, c.g, c.b));
        public void SetPlayerLeds(byte mask) => TactileException.Check(Native.tactile_controller_set_player_leds(handle, mask));
        public void SetMuteLed(MuteLed m) => TactileException.Check(Native.tactile_controller_set_mute_led(handle, (int)m));
        public void SetRumble(byte left, byte right) => TactileException.Check(Native.tactile_controller_set_rumble(handle, left, right));
        public void SetTrigger(TriggerSide side, TriggerEffect e) => TactileException.Check(Native.tactile_controller_set_trigger(handle, (int)side, ref e));
        public void Neutralize() => TactileException.Check(Native.tactile_controller_neutralize(handle));
        public Result LastError => (Result)Native.tactile_controller_last_error(handle);
        public void StartHaptics() => TactileException.Check(Native.tactile_haptics_start(handle));
        public void StopHaptics() => TactileException.Check(Native.tactile_haptics_stop(handle));
        public void Play(HapticEffect e, float intensity = 1f, HapticSide side = HapticSide.Both) =>
            TactileException.Check(Native.tactile_haptics_play(handle, (int)e, intensity, (int)side));

        /// <summary>Feeds audio (e.g. from OnAudioFilterRead) to the voice coils. One producer thread.</summary>
        public int WritePcm(float[] interleaved, int channels, int sampleRate) =>
            Native.tactile_haptics_write_pcm(handle, interleaved, interleaved.Length / Math.Max(channels, 1), channels, sampleRate);

        public void Dispose()
        {
            if (handle != IntPtr.Zero) { Native.tactile_controller_release(handle); handle = IntPtr.Zero; }
        }
    }

    public static class Triggers
    {
        static TriggerEffect Build(Func<TriggerEffect, (int, TriggerEffect)> f)
        {
            var e = new TriggerEffect { bytes = new byte[11] };
            var (r, outE) = f(e);
            TactileException.Check(r);
            return outE;
        }
        public static TriggerEffect Off() { var e = new TriggerEffect { bytes = new byte[11] }; Native.tactile_trigger_off(ref e); return e; }
        public static TriggerEffect Feedback(int position, int strength) => Build(e => (Native.tactile_trigger_feedback(position, strength, ref e), e));
        public static TriggerEffect Weapon(int start, int end, int strength) => Build(e => (Native.tactile_trigger_weapon(start, end, strength, ref e), e));
        public static TriggerEffect Vibration(int position, int amplitude, int frequency) => Build(e => (Native.tactile_trigger_vibration(position, amplitude, frequency, ref e), e));
        public static TriggerEffect SlopeFeedback(int sp, int ep, int ss, int es) => Build(e => (Native.tactile_trigger_slope_feedback(sp, ep, ss, es, ref e), e));
        public static TriggerEffect MultiplePositionFeedback(int[] strengths) => Build(e => (Native.tactile_trigger_multiple_position_feedback(strengths, ref e), e));
        public static TriggerEffect MultiplePositionVibration(int frequency, int[] amplitudes) => Build(e => (Native.tactile_trigger_multiple_position_vibration(frequency, amplitudes, ref e), e));
        /// <summary>Unofficial effect.</summary>
        public static TriggerEffect Bow(int start, int end, int strength, int snap) => Build(e => (Native.tactile_trigger_bow(start, end, strength, snap, ref e), e));
        /// <summary>Unofficial effect.</summary>
        public static TriggerEffect Galloping(int start, int end, int foot1, int foot2, int freq) => Build(e => (Native.tactile_trigger_galloping(start, end, foot1, foot2, freq, ref e), e));
        /// <summary>Unofficial effect.</summary>
        public static TriggerEffect Machine(int start, int end, int a, int b, int freq, int period) => Build(e => (Native.tactile_trigger_machine(start, end, a, b, freq, period, ref e), e));
    }

    /// <summary>Add to a GameObject. Owns the Tactile context for the scene's lifetime.</summary>
    public sealed class TactileManager : MonoBehaviour
    {
        public bool exclusive;
        public TactileController Controller { get; private set; }
        public event Action<TactileController, ControllerEvent> ControllerChanged;

        IntPtr context;
        static readonly ConcurrentQueue<(IntPtr, ControllerEvent)> pending = new ConcurrentQueue<(IntPtr, ControllerEvent)>();
        static readonly EventCallback callback = OnNativeEvent;  // kept alive for the process lifetime

        [AOT.MonoPInvokeCallback(typeof(EventCallback))]
        static void OnNativeEvent(IntPtr user, IntPtr controller, int evt)
        {
            Native.tactile_controller_retain(controller);  // released on the main thread
            pending.Enqueue((controller, (ControllerEvent)evt));
        }

        void Awake()
        {
            if ((Native.tactile_abi_version() >> 16) != Native.AbiMajor)
            {
                Debug.LogError("Tactile: native library ABI mismatch");
                enabled = false;
                return;
            }
            if (Native.tactile_permission_status() != (int)Permission.Granted) Native.tactile_permission_request();
            var o = new NativeOptions { struct_size = 16, mode = exclusive ? 1 : 0 };
            TactileException.Check(Native.tactile_context_create(ref o, out context));
            Native.tactile_context_set_callback(context, callback, IntPtr.Zero);
        }

        void Update()
        {
            while (pending.TryDequeue(out var item))
            {
                var (h, evt) = item;
                if (evt == ControllerEvent.Disconnected)
                {
                    ControllerChanged?.Invoke(Controller, evt);
                    Native.tactile_controller_release(h);
                    continue;
                }
                if (Controller == null) Controller = new TactileController(h);
                else Native.tactile_controller_release(h);  // same controller or a second one; keep the first
                ControllerChanged?.Invoke(Controller, evt);
            }
        }

        void OnDestroy()
        {
            Controller?.Dispose();
            Controller = null;
            if (context != IntPtr.Zero)
            {
                Native.tactile_context_set_callback(context, null, IntPtr.Zero);
                Native.tactile_context_destroy(context);  // restores neutral output
                context = IntPtr.Zero;
            }
            while (pending.TryDequeue(out var item)) Native.tactile_controller_release(item.Item1);
        }
    }
}
