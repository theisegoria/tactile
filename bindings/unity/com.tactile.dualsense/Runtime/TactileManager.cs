// Managed wrapper: a MonoBehaviour that owns the context, marshals lifecycle
// events to the main thread and exposes one active controller.
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
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
        // Guards `handle` between WritePcm (audio thread) and Dispose (main thread),
        // so the native handle is never released while a write is using it.
        readonly object gate = new object();
        InputState state = NewState();
        internal TactileController(IntPtr retained) { handle = retained; }

        /// <summary>The native pointer; equal for every handle to the same physical controller.</summary>
        internal IntPtr Handle => handle;

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

        /// <summary>Feeds audio (e.g. from OnAudioFilterRead) to the voice coils. One producer thread.
        /// Safe to race with Dispose: once disposed it returns Result.NotConnected.</summary>
        public int WritePcm(float[] interleaved, int channels, int sampleRate)
        {
            lock (gate)
            {
                if (handle == IntPtr.Zero) return (int)Result.NotConnected;
                return Native.tactile_haptics_write_pcm(handle, interleaved, interleaved.Length / Math.Max(channels, 1), channels, sampleRate);
            }
        }

        public void Dispose()
        {
            lock (gate)
            {
                if (handle != IntPtr.Zero) { Native.tactile_controller_release(handle); handle = IntPtr.Zero; }
            }
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

    /// <summary>Add to a GameObject. Owns the Tactile context for the scene's lifetime.
    /// Exposes one active controller: the first to connect, replaced by another
    /// connected DualSense when the active one disconnects. ControllerChanged only
    /// reports events for the active controller (and the switch to a new one).
    /// Several managers may coexist; each has its own context and event queue.</summary>
    public sealed class TactileManager : MonoBehaviour
    {
        public bool exclusive;
        public TactileController Controller { get; private set; }
        public event Action<TactileController, ControllerEvent> ControllerChanged;

        IntPtr context;
        bool controllerConnected;
        GCHandle self;  // user_data for the native callback; freed after the context is destroyed
        readonly ConcurrentQueue<(IntPtr, ControllerEvent)> pending = new ConcurrentQueue<(IntPtr, ControllerEvent)>();
        static readonly EventCallback callback = OnNativeEvent;  // kept alive for the process lifetime

        [AOT.MonoPInvokeCallback(typeof(EventCallback))]
        static void OnNativeEvent(IntPtr user, IntPtr controller, int evt)
        {
            if (user == IntPtr.Zero || controller == IntPtr.Zero) return;
            if (!(GCHandle.FromIntPtr(user).Target is TactileManager owner)) return;
            Native.tactile_controller_retain(controller);  // released on the main thread
            owner.pending.Enqueue((controller, (ControllerEvent)evt));
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
            self = GCHandle.Alloc(this);
            Native.tactile_context_set_callback(context, callback, GCHandle.ToIntPtr(self));
        }

        void Update()
        {
            while (pending.TryDequeue(out var item))
            {
                var (h, evt) = item;
                bool isActive = Controller != null && Controller.Handle == h;
                if (evt == ControllerEvent.Disconnected)
                {
                    Native.tactile_controller_release(h);
                    if (!isActive) continue;  // another controller; not the one exposed
                    controllerConnected = false;
                    ControllerChanged?.Invoke(Controller, evt);
                    AdoptConnectedReplacement();
                    continue;
                }
                if (isActive)
                {
                    Native.tactile_controller_release(h);
                    controllerConnected = true;
                    ControllerChanged?.Invoke(Controller, evt);
                }
                else if (Controller == null || !controllerConnected)
                {
                    Adopt(h, evt);  // takes over the retained handle
                }
                else
                {
                    Native.tactile_controller_release(h);  // a second controller while the active one is connected
                }
            }
        }

        void Adopt(IntPtr retained, ControllerEvent evt)
        {
            Controller?.Dispose();
            Controller = new TactileController(retained);
            controllerConnected = true;
            ControllerChanged?.Invoke(Controller, evt);
        }

        // After the active controller disconnects, switches to another controller
        // that is already connected and reporting (its Connected event came while
        // the old one was active). Keeps the old one, awaiting reconnect, otherwise.
        void AdoptConnectedReplacement()
        {
            int n = Native.tactile_context_controller_count(context);
            for (int i = 0; i < n; i++)
            {
                if (Native.tactile_context_get_controller(context, i, out var c) != (int)Result.Ok || c == IntPtr.Zero) continue;
                var probe = new InputState { struct_size = 72 };
                if (c != Controller?.Handle && Native.tactile_controller_get_input(c, ref probe) == (int)Result.Ok)
                {
                    Adopt(c, ControllerEvent.Connected);
                    return;
                }
                Native.tactile_controller_release(c);
            }
        }

        void OnDestroy()
        {
            Controller?.Dispose();  // waits for an in-flight WritePcm
            Controller = null;
            controllerConnected = false;
            if (context != IntPtr.Zero)
            {
                Native.tactile_context_set_callback(context, null, IntPtr.Zero);
                Native.tactile_context_destroy(context);  // restores neutral output; no callback runs after it
                context = IntPtr.Zero;
            }
            if (self.IsAllocated) self.Free();
            while (pending.TryDequeue(out var item)) Native.tactile_controller_release(item.Item1);
        }
    }
}
