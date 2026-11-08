/*
 * tactile.h — C ABI for Tactile (DualSense / DualSense Edge over Bluetooth on macOS).
 *
 * ABI rules
 *   - Opaque handles, plain C structs, callbacks. No Swift types cross this boundary.
 *   - Every struct passed in or out begins with `uint32_t struct_size`; set it to
 *     sizeof(struct) before the call. The library fills only fields it knows about,
 *     so newer headers keep working with older libraries and vice versa.
 *   - Versioning: TACTILE_ABI_VERSION_MAJOR changes on any incompatible change.
 *     Call tactile_abi_version() at start-up and refuse to run if the major differs.
 *
 * Threading (see also the per-function notes)
 *   - Every function is safe to call from any thread unless marked otherwise.
 *   - Output calls (lightbar, LEDs, triggers, rumble) never block: they enqueue the
 *     change on a per-controller serial queue and return. Failures are recorded and
 *     readable with tactile_controller_last_error().
 *   - tactile_controller_get_input() never blocks; it copies the latest snapshot.
 *   - Callbacks run serially on an internal thread. Do not call
 *     tactile_context_destroy() from inside a callback.
 *
 * Copyright (c) 2026 Tactile contributors. MIT licence.
 * Not affiliated with or endorsed by Sony Interactive Entertainment.
 */
#ifndef TACTILE_H
#define TACTILE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TACTILE_ABI_VERSION_MAJOR 0
#define TACTILE_ABI_VERSION_MINOR 3
#define TACTILE_ABI_VERSION ((TACTILE_ABI_VERSION_MAJOR << 16) | TACTILE_ABI_VERSION_MINOR)

typedef enum tactile_result {
    TACTILE_OK = 0,
    TACTILE_ERR_INVALID_ARGUMENT = -1,
    TACTILE_ERR_NOT_CONNECTED = -2,
    TACTILE_ERR_PERMISSION = -3,   /* Input Monitoring not granted */
    TACTILE_ERR_IO = -4,
    TACTILE_ERR_UNSUPPORTED = -5,
    TACTILE_ERR_TIMEOUT = -6,
    TACTILE_ERR_BUSY = -7,         /* another process holds exclusive access */
    TACTILE_ERR_VERSION = -8,
    TACTILE_ERR_NOT_FOUND = -9
} tactile_result;

typedef enum tactile_model { TACTILE_MODEL_DUALSENSE = 0, TACTILE_MODEL_DUALSENSE_EDGE = 1 } tactile_model;
typedef enum tactile_transport { TACTILE_TRANSPORT_BLUETOOTH = 0, TACTILE_TRANSPORT_USB = 1 } tactile_transport;
typedef enum tactile_access_mode { TACTILE_MODE_SHARED = 0, TACTILE_MODE_EXCLUSIVE = 1 } tactile_access_mode;
typedef enum tactile_permission { TACTILE_PERMISSION_GRANTED = 0, TACTILE_PERMISSION_DENIED = 1, TACTILE_PERMISSION_NOT_DETERMINED = 2 } tactile_permission;
typedef enum tactile_trigger_side { TACTILE_TRIGGER_LEFT = 0, TACTILE_TRIGGER_RIGHT = 1 } tactile_trigger_side;
typedef enum tactile_mute_led { TACTILE_MUTE_LED_OFF = 0, TACTILE_MUTE_LED_ON = 1, TACTILE_MUTE_LED_PULSE = 2 } tactile_mute_led;
typedef enum tactile_haptic_side { TACTILE_HAPTIC_LEFT = 0, TACTILE_HAPTIC_RIGHT = 1, TACTILE_HAPTIC_BOTH = 2 } tactile_haptic_side;
typedef enum tactile_haptic_effect {
    TACTILE_HAPTIC_CLICK = 0, TACTILE_HAPTIC_DETENT = 1, TACTILE_HAPTIC_TEXTURE = 2, TACTILE_HAPTIC_IMPACT = 3
} tactile_haptic_effect;
typedef enum tactile_event {
    TACTILE_EVENT_CONNECTED = 0,
    TACTILE_EVENT_RECONNECTED = 1,
    TACTILE_EVENT_DISCONNECTED = 2,
    /* ABI 0.2: the controller's player number changed (read it with
     * tactile_controller_get_player; 0 means it no longer has one). */
    TACTILE_EVENT_PLAYER_CHANGED = 3
} tactile_event;

/* ABI 0.3: audio output path (common output block byte 7, bits 4-5).
 * Research-grade: unverified on hardware. */
typedef enum tactile_audio_path {
    TACTILE_AUDIO_PATH_HEADPHONES = 0,
    TACTILE_AUDIO_PATH_HEADPHONE_LEFT = 1,             /* mono headset */
    TACTILE_AUDIO_PATH_HEADPHONE_LEFT_AND_SPEAKER = 2,
    TACTILE_AUDIO_PATH_SPEAKER = 3
} tactile_audio_path;

/* ABI 0.3: capability bits in tactile_controller_info.capabilities. A bit
 * means the path is implemented for this controller and transport; bits also
 * set in capabilities_unverified rest on protocol facts not yet confirmed on
 * hardware (PROTOCOL.md). */
#define TACTILE_CAP_ADAPTIVE_TRIGGERS  (1u << 0)
#define TACTILE_CAP_LIGHTS             (1u << 1)  /* lightbar, player LEDs, mute LED */
#define TACTILE_CAP_IMU                (1u << 2)  /* calibrated gyro/accel */
#define TACTILE_CAP_TOUCHPAD           (1u << 3)
#define TACTILE_CAP_RUMBLE             (1u << 4)  /* legacy rumble in output report 0x31/0x02 */
#define TACTILE_CAP_VIBRATION_V2       (1u << 5)  /* firmware uses compatible-vibration-2 */
#define TACTILE_CAP_EDGE_CONTROLS      (1u << 6)  /* Fn and back paddles */
#define TACTILE_CAP_HID_HAPTICS        (1u << 7)  /* Bluetooth 0x32 audio haptics (tactile_haptics_*) */
#define TACTILE_CAP_USB_AUDIO_HAPTICS  (1u << 8)  /* USB: haptics on the pad's USB audio device, not via Tactile */
#define TACTILE_CAP_HID_SPEAKER        (1u << 9)  /* Bluetooth 0x36 speaker (tactile_speaker_*) */
#define TACTILE_CAP_USB_AUDIO_SPEAKER  (1u << 10) /* USB: speaker/jack on the pad's USB audio device */
#define TACTILE_CAP_AUDIO_ROUTING      (1u << 11) /* tactile_controller_set_audio */
#define TACTILE_CAP_HEADSET_DETECT     (1u << 12) /* tactile_input_state.headphones/microphone */

/* ABI 0.3: the pad's USB audio function (USB only; Tactile does not open it).
 * Product strings are what the pad reports over USB, so an engine can match
 * the Core Audio device; prefer matching vendor/product IDs in the model UID.
 * Channel order on the 4-channel output: research-grade, unverified. */
#define TACTILE_USB_PRODUCT_NAME_DUALSENSE       "DualSense Wireless Controller"
#define TACTILE_USB_PRODUCT_NAME_DUALSENSE_EDGE  "DualSense Edge Wireless Controller"
#define TACTILE_VENDOR_ID_SONY                   0x054C
#define TACTILE_PRODUCT_ID_DUALSENSE             0x0CE6
#define TACTILE_PRODUCT_ID_DUALSENSE_EDGE        0x0DF2
#define TACTILE_USB_AUDIO_OUTPUT_CHANNELS        4
#define TACTILE_USB_AUDIO_CHANNEL_SPEAKER_LEFT   0  /* speaker / headset left */
#define TACTILE_USB_AUDIO_CHANNEL_SPEAKER_RIGHT  1  /* speaker / headset right */
#define TACTILE_USB_AUDIO_CHANNEL_HAPTIC_LEFT    2  /* left grip actuator */
#define TACTILE_USB_AUDIO_CHANNEL_HAPTIC_RIGHT   3  /* right grip actuator */

/* Button bits in tactile_input_state.buttons. */
#define TACTILE_BUTTON_SQUARE       (1u << 0)
#define TACTILE_BUTTON_CROSS        (1u << 1)
#define TACTILE_BUTTON_CIRCLE       (1u << 2)
#define TACTILE_BUTTON_TRIANGLE     (1u << 3)
#define TACTILE_BUTTON_L1           (1u << 4)
#define TACTILE_BUTTON_R1           (1u << 5)
#define TACTILE_BUTTON_L2           (1u << 6)
#define TACTILE_BUTTON_R2           (1u << 7)
#define TACTILE_BUTTON_CREATE       (1u << 8)
#define TACTILE_BUTTON_OPTIONS      (1u << 9)
#define TACTILE_BUTTON_L3           (1u << 10)
#define TACTILE_BUTTON_R3           (1u << 11)
#define TACTILE_BUTTON_PS           (1u << 12)
#define TACTILE_BUTTON_TOUCHPAD     (1u << 13)
#define TACTILE_BUTTON_MUTE         (1u << 14)
#define TACTILE_BUTTON_DPAD_UP      (1u << 15)
#define TACTILE_BUTTON_DPAD_RIGHT   (1u << 16)
#define TACTILE_BUTTON_DPAD_DOWN    (1u << 17)
#define TACTILE_BUTTON_DPAD_LEFT    (1u << 18)
#define TACTILE_BUTTON_FN_LEFT      (1u << 19) /* Edge */
#define TACTILE_BUTTON_FN_RIGHT     (1u << 20) /* Edge */
#define TACTILE_BUTTON_PADDLE_LEFT  (1u << 21) /* Edge */
#define TACTILE_BUTTON_PADDLE_RIGHT (1u << 22) /* Edge */

typedef struct tactile_context tactile_context;       /* opaque */
typedef struct tactile_controller tactile_controller; /* opaque, reference counted */

typedef struct tactile_options {
    uint32_t struct_size;
    int32_t mode;                 /* tactile_access_mode; default SHARED */
    double max_output_reports_per_second; /* 0 = default (125) */
} tactile_options;

typedef struct tactile_input_state {
    uint32_t struct_size;
    uint8_t left_x, left_y, right_x, right_y; /* 0..255, 128 = centre */
    uint8_t l2, r2;                           /* analogue triggers 0..255 */
    uint8_t has_imu, has_touch;
    uint32_t buttons;                         /* TACTILE_BUTTON_* */
    float gyro_dps[3];                        /* calibrated, degrees/second */
    float accel_g[3];                         /* calibrated, g */
    uint32_t sensor_timestamp;
    uint8_t touch_active[2];
    uint8_t touch_id[2];
    uint16_t touch_x[2];                      /* 0..1919 */
    uint16_t touch_y[2];                      /* 0..1079 */
    int32_t battery_percent;                  /* -1 if unknown */
    int32_t battery_charging;                 /* 0 discharging, 1 charging, 2 full, -1 unknown/error */
    uint64_t report_count;                    /* increments per input report */
    /* ABI 0.3 (struct_size >= 88): */
    int8_t headphones;                        /* 1 plugged, 0 not, -1 unknown (status byte 53 bit 0) */
    int8_t microphone;                        /* 1 plugged, 0 not, -1 unknown (status byte 53 bit 1) */
    uint8_t reserved0[6];
    uint64_t host_time_ns;                    /* report arrival, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) */
} tactile_input_state;

typedef struct tactile_controller_info {
    uint32_t struct_size;
    int32_t model;                            /* tactile_model */
    int32_t transport;                        /* tactile_transport */
    char address[18];                         /* "02:11:22:33:44:55", NUL-terminated, or "" */
    uint32_t firmware_version;
    uint32_t hardware_version;
    uint16_t update_version;                  /* major << 8 | minor */
    uint8_t vibration_v2;
    uint8_t connected;
    /* ABI 0.3 (struct_size >= 116): */
    uint16_t vendor_id;                       /* TACTILE_VENDOR_ID_SONY */
    uint16_t product_id;                      /* TACTILE_PRODUCT_ID_* */
    uint32_t capabilities;                    /* TACTILE_CAP_* */
    uint32_t capabilities_unverified;         /* subset of capabilities not yet confirmed on hardware */
    char product[60];                         /* HID product string, NUL-terminated, or "" */
} tactile_controller_info;

typedef struct tactile_trigger_effect {
    uint8_t bytes[11];                        /* wire encoding; build with tactile_trigger_* */
} tactile_trigger_effect;

typedef struct tactile_haptics_metrics {
    uint32_t struct_size;
    uint64_t reports_sent;
    uint64_t reports_dropped;
    uint64_t underrun_ticks;
    double wake_lateness_p99_us;
    double tick_interval_stddev_us;
    double send_latency_mean_us;
    double send_latency_p99_us;
    double pump_cpu_percent;
    /* ABI 0.3 (struct_size >= 104): */
    double buffered_ms;                       /* streamed PCM waiting in the ring */
    double report_period_us;                  /* 10666.7: one 0x32 report per 32 frames at 3 kHz */
    double estimated_latency_ms;              /* buffered + one period + mean send latency; air link excluded */
    uint32_t running;                         /* the pump is installed and running */
    uint32_t sending;                         /* 0x32 reports are going out; 0 once idle (~85 ms of silence) */
} tactile_haptics_metrics;

/* ABI 0.3: audio volume and routing. -1 leaves a field unchanged (its valid
 * flag stays clear). Volumes: headphone 0-127, speaker 0-255, mic 0-64
 * (clamped). Research-grade ranges, unverified on hardware. */
typedef struct tactile_audio_settings {
    uint32_t struct_size;
    int32_t headphone_volume;
    int32_t speaker_volume;
    int32_t mic_volume;
    int32_t output_path;                      /* tactile_audio_path, or -1 */
} tactile_audio_settings;

typedef struct tactile_speaker tactile_speaker; /* opaque (ABI 0.3) */

typedef struct tactile_speaker_options {
    uint32_t struct_size;
    int32_t bit_rate;                         /* Opus bits/s; 0 = 96000 */
    int32_t queue_ms;                         /* most audio queued; 0 = 250 */
    int32_t idle_ms;                          /* silence before the stream ends; 0 = 500 */
} tactile_speaker_options;

typedef struct tactile_speaker_stats {
    uint32_t struct_size;
    uint32_t streaming;                       /* 1 while 0x36 reports are going out */
    uint64_t packets_sent;
    uint64_t silence_packets;                 /* underrun padding */
    uint64_t frames_dropped;                  /* refused because the queue was full */
    uint64_t packets_dropped_oversize;
    uint64_t send_failures;
    uint32_t queued_frames;                   /* 48 kHz frames waiting */
    uint32_t max_packet_bytes;                /* largest Opus packet the report fits */
    uint32_t largest_packet;
    uint32_t reserved0;
    double queued_ms;
    double send_latency_mean_us;              /* deadline to set-report completion */
    double estimated_latency_ms;              /* queued + one 10 ms packet + mean send latency; air link excluded */
} tactile_speaker_stats;

typedef void (*tactile_event_callback)(void *user_data, tactile_controller *controller, int32_t event);

/* ---- Library ---------------------------------------------------------- */

/* Returns TACTILE_ABI_VERSION of the loaded library. Thread-safe. */
uint32_t tactile_abi_version(void);
/* Static string, e.g. "0.3.0". Thread-safe. */
const char *tactile_version_string(void);
/* Human-readable text for a result code (static string). Thread-safe. */
const char *tactile_result_string(int32_t result);

/* Input Monitoring permission. request() may show a system prompt (first time only). */
int32_t tactile_permission_status(void);
int32_t tactile_permission_request(void);

/* ---- Context ---------------------------------------------------------- */

/* Starts discovery. `options` may be NULL for defaults. Thread-safe. */
int32_t tactile_context_create(const tactile_options *options, tactile_context **out_context);
/* Restores every controller to neutral, closes them and frees the context.
 * Blocks until done. Output already queued is applied (or fails) before the
 * neutral report, never after it. Once it returns, no callback is running or
 * will run, and controller handles are invalidated: they remain safe to
 * release, but every call on them returns TACTILE_ERR_NOT_CONNECTED (except
 * tactile_haptics_stop, a no-op returning TACTILE_OK) and get_info reports
 * connected = 0. Not callable from a callback. */
void tactile_context_destroy(tactile_context *context);
/* Registers a lifecycle callback (replaces any previous one; NULL removes).
 * The controller pointer is borrowed for the duration of the call; retain it
 * with tactile_controller_retain() to keep it.
 * Called from outside a callback, this waits for a running invocation of the
 * previous callback to finish; once it returns, the previous callback and its
 * user_data are never used again and may be freed. (Don't make a callback wait
 * on the thread calling this, or both wait forever.) Called from inside a
 * callback, it takes effect for every later invocation. */
void tactile_context_set_callback(tactile_context *context, tactile_event_callback callback, void *user_data);
/* Number of controllers seen (connected or awaiting reconnect). */
int32_t tactile_context_controller_count(tactile_context *context);
/* Returns a retained handle; release with tactile_controller_release(). */
int32_t tactile_context_get_controller(tactile_context *context, int32_t index, tactile_controller **out_controller);
/* Blocks up to timeout_ms for a connected controller. Returns a retained handle.
 * On timeout: TACTILE_ERR_PERMISSION without Input Monitoring permission;
 * otherwise the error of the latest controller that failed to open since the
 * previous wait (e.g. TACTILE_ERR_BUSY when another process holds exclusive
 * access), else TACTILE_ERR_TIMEOUT.
 * Do not call on a thread that must stay responsive. */
int32_t tactile_context_wait_for_controller(tactile_context *context, int32_t timeout_ms, tactile_controller **out_controller);

/* ---- Players: local multiplayer / split screen (ABI 0.2) --------------
 * Every context numbers its controllers 1..max_players in the order they
 * connect. A controller that disconnects keeps its number and gets it back on
 * reconnect (when every slot is taken, the lowest slot held for a
 * disconnected controller is reused). All calls are thread-safe and
 * non-blocking. */

/* max_players: 1-8, or 0 to keep the current value (default 4).
 * apply_lights: 1 = show the player number on the player LEDs and the player
 * colour (blue, red, green, pink) on the lightbar whenever a controller gains
 * or changes its number; 0 = never touch them (default); -1 = keep. */
int32_t tactile_context_set_player_options(tactile_context *context, int32_t max_players, int32_t apply_lights);
/* Retained handle of the controller holding `player` (1-based), which may be
 * disconnected while its slot is held; TACTILE_ERR_NOT_FOUND if the slot is empty. */
int32_t tactile_context_get_player(tactile_context *context, int32_t player, tactile_controller **out_controller);
/* Moves `controller` to `player`, swapping with the current occupant. */
int32_t tactile_context_assign_player(tactile_context *context, tactile_controller *controller, int32_t player);
/* Empties `player`'s slot. */
int32_t tactile_context_release_player(tactile_context *context, int32_t player);
/* The controller's player number (1-8), 0 if it has none, or a negative tactile_result. */
int32_t tactile_controller_get_player(tactile_controller *controller);

/* ---- Controller ------------------------------------------------------- */

void tactile_controller_retain(tactile_controller *controller);
void tactile_controller_release(tactile_controller *controller);

int32_t tactile_controller_get_info(tactile_controller *controller, tactile_controller_info *out_info);
/* Non-blocking copy of the latest input. TACTILE_ERR_NOT_CONNECTED when no
 * report has arrived yet or the controller is disconnected. */
int32_t tactile_controller_get_input(tactile_controller *controller, tactile_input_state *out_state);

/* Non-blocking output. Values are applied in call order. */
int32_t tactile_controller_set_lightbar(tactile_controller *controller, uint8_t r, uint8_t g, uint8_t b);
int32_t tactile_controller_set_player_leds(tactile_controller *controller, uint8_t mask); /* bits 0-4, bit 5 = instant */
int32_t tactile_controller_set_mute_led(tactile_controller *controller, int32_t mode);   /* tactile_mute_led */
int32_t tactile_controller_set_rumble(tactile_controller *controller, uint8_t left, uint8_t right);
int32_t tactile_controller_set_trigger(tactile_controller *controller, int32_t side, const tactile_trigger_effect *effect);
/* Triggers off, rumble off, lightbar restored. Non-blocking. */
int32_t tactile_controller_neutralize(tactile_controller *controller);
/* Result of the most recent failed asynchronous operation (TACTILE_OK if none);
 * reading it clears it. */
int32_t tactile_controller_last_error(tactile_controller *controller);

/* ---- Trigger effect builders (pure; thread-safe) ---------------------- */

void    tactile_trigger_off(tactile_trigger_effect *out);
int32_t tactile_trigger_feedback(int32_t position, int32_t strength, tactile_trigger_effect *out);
int32_t tactile_trigger_weapon(int32_t start, int32_t end, int32_t strength, tactile_trigger_effect *out);
int32_t tactile_trigger_vibration(int32_t position, int32_t amplitude, int32_t frequency, tactile_trigger_effect *out);
int32_t tactile_trigger_slope_feedback(int32_t start_position, int32_t end_position, int32_t start_strength, int32_t end_strength, tactile_trigger_effect *out);
int32_t tactile_trigger_multiple_position_feedback(const int32_t strengths[10], tactile_trigger_effect *out);
int32_t tactile_trigger_multiple_position_vibration(int32_t frequency, const int32_t amplitudes[10], tactile_trigger_effect *out);
/* Unofficial effects. */
int32_t tactile_trigger_bow(int32_t start, int32_t end, int32_t strength, int32_t snap_force, tactile_trigger_effect *out);
int32_t tactile_trigger_galloping(int32_t start, int32_t end, int32_t first_foot, int32_t second_foot, int32_t frequency, tactile_trigger_effect *out);
int32_t tactile_trigger_machine(int32_t start, int32_t end, int32_t amplitude_a, int32_t amplitude_b, int32_t frequency, int32_t period, tactile_trigger_effect *out);

/* ---- Haptics (Bluetooth) ---------------------------------------------- */

/* Starts/stops the 0x32 audio-haptics pump. While running, rumble is emulated
 * on the voice coils. Blocking (briefly). */
int32_t tactile_haptics_start(tactile_controller *controller);
int32_t tactile_haptics_stop(tactile_controller *controller);
/* Plays a parametric effect; intensity 0..1. Non-blocking; starts the pump if needed. */
int32_t tactile_haptics_play(tactile_controller *controller, int32_t effect, float intensity, int32_t side);
/* Queues float PCM (interleaved, 1 or 2+ channels, any sample rate). Non-blocking.
 * Single producer: call from one thread at a time per controller.
 * Requires tactile_haptics_start() (or a running pump from tactile_haptics_play):
 * while haptics are stopped nothing is queued and it returns 0, so audio never
 * plays late. Returns the number of 3 kHz frames queued, or a negative
 * tactile_result. */
int32_t tactile_haptics_write_pcm(tactile_controller *controller, const float *interleaved, int32_t frames, int32_t channels, double sample_rate);
/* Pump diagnostics. All zero (TACTILE_OK) while haptics are stopped;
 * TACTILE_ERR_NOT_CONNECTED only when the controller is disconnected. */
int32_t tactile_haptics_get_metrics(tactile_controller *controller, tactile_haptics_metrics *out_metrics);

/* ---- Audio and speaker (ABI 0.3; research-grade, unverified) -----------
 * Routing and volume go in output report 0x31 (Bluetooth) or 0x02 (USB), so
 * tactile_controller_set_audio works on both transports. Speaker audio:
 *   - Bluetooth: tactile_speaker_* encodes PCM (any rate, resampled to 48 kHz) as Opus (CELT, 10 ms
 *     packets) into output report 0x36, sized from the pad's report
 *     descriptor, on the controller's own connection (no second connection).
 *   - USB: play through the pad's USB audio device (TACTILE_USB_AUDIO_*);
 *     tactile_speaker_open returns TACTILE_ERR_UNSUPPORTED.
 * The headset state is tactile_input_state.headphones / .microphone. */

/* Non-blocking, applied in call order like the other output calls. */
int32_t tactile_controller_set_audio(tactile_controller *controller, const tactile_audio_settings *settings);

/* Opens a speaker stream (options may be NULL). TACTILE_ERR_UNSUPPORTED over
 * USB or when the descriptor declares no report 0x36. The stream follows the
 * controller across reconnects. Thread-safe. Closing it before
 * tactile_context_destroy is not required: afterwards its calls return
 * TACTILE_ERR_NOT_CONNECTED and close stays safe. */
int32_t tactile_speaker_open(tactile_controller *controller, const tactile_speaker_options *options, tactile_speaker **out_speaker);
/* Stops the stream, drops queued audio and frees the handle. Blocks briefly. */
void tactile_speaker_close(tactile_speaker *speaker);
/* Queues float PCM at any sample_rate (1-768000 Hz; resampled to 48 kHz when
 * it differs). 1 channel is duplicated; beyond 2 are dropped. Non-blocking,
 * single producer. Returns the number of 48 kHz frames queued (fewer when the
 * queue is full) or a negative tactile_result. Underruns play silence; after
 * idle_ms of silence the stream ends and the next write restarts it. */
int32_t tactile_speaker_write_pcm(tactile_speaker *speaker, const float *interleaved, int32_t frames, int32_t channels, double sample_rate);
/* Queues one pre-encoded Opus packet (CELT, 48 kHz stereo, 10 ms). Returns
 * TACTILE_OK, TACTILE_ERR_BUSY when the queue is full, or
 * TACTILE_ERR_INVALID_ARGUMENT when it does not fit the report. */
int32_t tactile_speaker_write_opus(tactile_speaker *speaker, const uint8_t *packet, int32_t size);
/* Drops queued audio. Non-blocking. */
int32_t tactile_speaker_flush(tactile_speaker *speaker);
int32_t tactile_speaker_get_stats(tactile_speaker *speaker, tactile_speaker_stats *out_stats);

#ifdef __cplusplus
}
#endif

#endif /* TACTILE_H */
