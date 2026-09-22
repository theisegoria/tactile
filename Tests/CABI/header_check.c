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
STATIC_ASSERT(sizeof(tactile_input_state) == 72, "input state size");
STATIC_ASSERT(sizeof(tactile_controller_info) == 44, "controller info size");

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
    tactile_controller_release(NULL);
    tactile_context_destroy(NULL);

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
