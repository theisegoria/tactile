/* C ABI check: compiles the public header under strict C and C++ settings,
 * checks struct layout invariants, links against libCTactile and verifies
 * pure (hardware-free) entry points. Run via scripts/check-c-abi.sh. */
#include "tactile.h"
#include <stdio.h>
#include <string.h>
#include <assert.h>

#if defined(__cplusplus)
#define STATIC_ASSERT(c, m) static_assert(c, m)
#else
#define STATIC_ASSERT(c, m) _Static_assert(c, m)
#endif

/* Layout invariants that bindings (P/Invoke, ctypes, GDExtension) rely on. */
STATIC_ASSERT(offsetof(tactile_input_state, struct_size) == 0, "struct_size first");
STATIC_ASSERT(offsetof(tactile_controller_info, struct_size) == 0, "struct_size first");
STATIC_ASSERT(offsetof(tactile_haptics_metrics, struct_size) == 0, "struct_size first");
STATIC_ASSERT(offsetof(tactile_options, struct_size) == 0, "struct_size first");
STATIC_ASSERT(sizeof(tactile_trigger_effect) == 11, "trigger effect is 11 bytes");
STATIC_ASSERT(offsetof(tactile_input_state, buttons) == 12, "buttons offset");
STATIC_ASSERT(offsetof(tactile_input_state, gyro_dps) == 16, "gyro offset");
/* ABI 0.3 appends fields; the 0.2 prefix must not move. */
STATIC_ASSERT(offsetof(tactile_input_state, report_count) == 64, "0.2 input prefix");
STATIC_ASSERT(offsetof(tactile_input_state, headphones) == 72, "0.3 headset after 0.2 prefix");
STATIC_ASSERT(offsetof(tactile_input_state, host_time_ns) == 80, "host time offset");
STATIC_ASSERT(sizeof(tactile_input_state) == 88, "input state size");
STATIC_ASSERT(offsetof(tactile_controller_info, connected) == 43, "0.2 info prefix");
STATIC_ASSERT(offsetof(tactile_controller_info, vendor_id) == 44, "0.3 identity after 0.2 prefix");
STATIC_ASSERT(sizeof(tactile_controller_info) == 116, "controller info size");
STATIC_ASSERT(offsetof(tactile_haptics_metrics, pump_cpu_percent) == 64, "0.2 metrics prefix");
STATIC_ASSERT(offsetof(tactile_haptics_metrics, buffered_ms) == 72, "0.3 metrics after 0.2 prefix");
STATIC_ASSERT(sizeof(tactile_haptics_metrics) == 104, "metrics size");
STATIC_ASSERT(offsetof(tactile_audio_settings, struct_size) == 0, "struct_size first");
STATIC_ASSERT(sizeof(tactile_audio_settings) == 20, "audio settings size");
STATIC_ASSERT(offsetof(tactile_speaker_options, struct_size) == 0, "struct_size first");
STATIC_ASSERT(offsetof(tactile_speaker_stats, struct_size) == 0, "struct_size first");
STATIC_ASSERT(sizeof(tactile_speaker_stats) == 88, "speaker stats size");

static int failures = 0;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static int bytes_eq(const tactile_trigger_effect *e, const unsigned char *want) {
    return memcmp(e->bytes, want, 11) == 0;
}

static void on_event(void *user_data, tactile_controller *controller, int32_t event) {
    (void)user_data; (void)controller; (void)event;
}

int main(void) {
    tactile_trigger_effect e;
    CHECK(tactile_abi_version() == TACTILE_ABI_VERSION);
    CHECK(strlen(tactile_version_string()) > 0);
    CHECK(strcmp(tactile_result_string(TACTILE_ERR_PERMISSION), "Input Monitoring permission required") == 0);

    /* Golden vectors: same as Tests/TactileCoreTests/TriggerEffectTests.swift. */
    {
        const unsigned char want[11] = {0x25, 0x44, 0x00, 0x07};
        CHECK(tactile_trigger_weapon(2, 6, 8, &e) == TACTILE_OK && bytes_eq(&e, want));
    }
    {
        const unsigned char want[11] = {0x21, 0xf8, 0x03, 0x00, 0x48, 0x92, 0x24};
        CHECK(tactile_trigger_feedback(3, 5, &e) == TACTILE_OK && bytes_eq(&e, want));
    }
    {
        const unsigned char want[11] = {0x27, 0x02, 0x02, 0x3b, 0x05, 0x03};
        CHECK(tactile_trigger_machine(1, 9, 3, 7, 5, 3, &e) == TACTILE_OK && bytes_eq(&e, want));
    }
    {
        const unsigned char want[11] = {0x05};
        tactile_trigger_off(&e);
        CHECK(bytes_eq(&e, want));
    }
    {
        const int32_t s[10] = {0, 0, 8, 6, 4, 3, 1, 1, 1, 1};
        const unsigned char want[11] = {0x21, 0xfc, 0x03, 0xc0, 0x3b, 0x01};
        CHECK(tactile_trigger_multiple_position_feedback(s, &e) == TACTILE_OK && bytes_eq(&e, want));
    }
    CHECK(tactile_trigger_weapon(1, 6, 8, &e) == TACTILE_ERR_INVALID_ARGUMENT);
    CHECK(tactile_trigger_feedback(3, 5, NULL) == TACTILE_ERR_INVALID_ARGUMENT);

    /* NULL handles are rejected, never dereferenced. */
    CHECK(tactile_controller_set_lightbar(NULL, 1, 2, 3) == TACTILE_ERR_INVALID_ARGUMENT);
    CHECK(tactile_controller_get_input(NULL, NULL) == TACTILE_ERR_INVALID_ARGUMENT);
    CHECK(tactile_context_controller_count(NULL) == 0);
    /* Players (ABI 0.2): NULL handles and out-of-range arguments are rejected. */
    CHECK(TACTILE_EVENT_PLAYER_CHANGED == 3);
    CHECK(tactile_context_get_player(NULL, 1, NULL) == TACTILE_ERR_INVALID_ARGUMENT);
    CHECK(tactile_context_assign_player(NULL, NULL, 1) == TACTILE_ERR_INVALID_ARGUMENT);
    CHECK(tactile_context_release_player(NULL, 1) == TACTILE_ERR_INVALID_ARGUMENT);
    CHECK(tactile_context_set_player_options(NULL, 4, 1) == TACTILE_ERR_INVALID_ARGUMENT);
    CHECK(tactile_controller_get_player(NULL) == TACTILE_ERR_INVALID_ARGUMENT);
    tactile_controller_release(NULL);
    tactile_context_destroy(NULL);
    /* Audio and speaker (ABI 0.3). */
    CHECK(TACTILE_ABI_VERSION_MINOR >= 3);
    CHECK(TACTILE_AUDIO_PATH_SPEAKER == 3 && TACTILE_USB_AUDIO_CHANNEL_HAPTIC_LEFT == 2);
    CHECK(TACTILE_PRODUCT_ID_DUALSENSE_EDGE == 0x0DF2);
    CHECK(strcmp(TACTILE_USB_PRODUCT_NAME_DUALSENSE_EDGE, "DualSense Edge Wireless Controller") == 0);
    {
        tactile_audio_settings a;
        tactile_speaker *sp = NULL;
        tactile_speaker_stats st;
        float pcm[2] = {0, 0};
        const uint8_t pkt[1] = {0xF4};
        memset(&a, 0, sizeof a); a.struct_size = sizeof a;
        memset(&st, 0, sizeof st); st.struct_size = sizeof st;
        CHECK(tactile_controller_set_audio(NULL, &a) == TACTILE_ERR_INVALID_ARGUMENT);
        CHECK(tactile_speaker_open(NULL, NULL, &sp) == TACTILE_ERR_INVALID_ARGUMENT && sp == NULL);
        CHECK(tactile_speaker_write_pcm(NULL, pcm, 1, 2, 48000.0) == TACTILE_ERR_INVALID_ARGUMENT);
        CHECK(tactile_speaker_write_opus(NULL, pkt, 1) == TACTILE_ERR_INVALID_ARGUMENT);
        CHECK(tactile_speaker_flush(NULL) == TACTILE_ERR_INVALID_ARGUMENT);
        CHECK(tactile_speaker_get_stats(NULL, &st) == TACTILE_ERR_INVALID_ARGUMENT);
        tactile_speaker_close(NULL);
    }

    /* Context lifecycle without hardware: replacing/removing the callback from
     * outside a callback fences it without deadlocking, discovery-time lookups
     * behave, and destroy returns. */
    {
        tactile_context *ctx = NULL;
        tactile_controller *h = NULL;
        int user = 0;
        CHECK(tactile_context_create(NULL, &ctx) == TACTILE_OK && ctx != NULL);
        tactile_context_set_callback(ctx, on_event, &user);
        tactile_context_set_callback(ctx, on_event, NULL);
        tactile_context_set_callback(ctx, NULL, NULL);
        CHECK(tactile_context_get_controller(ctx, 99, &h) == TACTILE_ERR_NOT_FOUND);
        CHECK(tactile_context_get_controller(ctx, -1, &h) == TACTILE_ERR_NOT_FOUND);
        if (tactile_context_controller_count(ctx) == 0) {
            int32_t r = tactile_context_wait_for_controller(ctx, 0, &h);
            CHECK(r == TACTILE_ERR_TIMEOUT || r == TACTILE_ERR_PERMISSION || r == TACTILE_ERR_BUSY || r == TACTILE_OK);
            if (r == TACTILE_OK) tactile_controller_release(h);
        }
        tactile_context_set_callback(ctx, on_event, &user);
        tactile_context_destroy(ctx);
    }

    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("C ABI check passed (ABI %u.%u, library %s)\n",
           tactile_abi_version() >> 16, tactile_abi_version() & 0xffff, tactile_version_string());
    return 0;
}
