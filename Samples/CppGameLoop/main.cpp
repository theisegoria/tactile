// A minimal C++ game loop over the Tactile C ABI:
//  - polls input every frame (60 Hz)
//  - Cross → haptic click; Circle → toggles a weapon trigger effect on R2
//  - left stick drives the lightbar colour
// Build: see Samples/CppGameLoop/build.sh
#include "tactile.h"

#include <chrono>
#include <csignal>
#include <cstdio>
#include <thread>

static volatile std::sig_atomic_t g_quit = 0;

int main() {
    if ((tactile_abi_version() >> 16) != TACTILE_ABI_VERSION_MAJOR) {
        std::fprintf(stderr, "ABI mismatch: header %d, library %u\n", TACTILE_ABI_VERSION_MAJOR, tactile_abi_version() >> 16);
        return 1;
    }
    std::signal(SIGINT, [](int) { g_quit = 1; });

    if (tactile_permission_status() != TACTILE_PERMISSION_GRANTED) tactile_permission_request();

    tactile_context *ctx = nullptr;
    tactile_options opts{};
    opts.struct_size = sizeof opts;
    opts.mode = TACTILE_MODE_SHARED;
    tactile_context_create(&opts, &ctx);

    tactile_controller *pad = nullptr;
    int32_t r = tactile_context_wait_for_controller(ctx, 5000, &pad);
    if (r != TACTILE_OK) {
        std::fprintf(stderr, "no controller: %s\n", tactile_result_string(r));
        tactile_context_destroy(ctx);
        return 1;
    }
    tactile_controller_info info{};
    info.struct_size = sizeof info;
    tactile_controller_get_info(pad, &info);
    std::printf("%s over %s, address %s\n", info.model == TACTILE_MODEL_DUALSENSE_EDGE ? "DualSense Edge" : "DualSense",
                info.transport == TACTILE_TRANSPORT_USB ? "USB" : "Bluetooth", info.address);

    tactile_trigger_effect weapon{}, off{};
    tactile_trigger_weapon(3, 6, 8, &weapon);
    tactile_trigger_off(&off);
    bool weaponOn = false;
    uint32_t prev = 0;
    auto frame = std::chrono::steady_clock::now();

    std::printf("Cross = click, Circle = toggle R2 weapon, left stick = lightbar, Options = quit\n");
    while (!g_quit) {
        tactile_input_state in{};
        in.struct_size = sizeof in;
        if (tactile_controller_get_input(pad, &in) == TACTILE_OK) {
            uint32_t pressed = in.buttons & ~prev;
            prev = in.buttons;
            if (pressed & TACTILE_BUTTON_CROSS) tactile_haptics_play(pad, TACTILE_HAPTIC_CLICK, 1.0f, TACTILE_HAPTIC_BOTH);
            if (pressed & TACTILE_BUTTON_CIRCLE) {
                weaponOn = !weaponOn;
                tactile_controller_set_trigger(pad, TACTILE_TRIGGER_RIGHT, weaponOn ? &weapon : &off);
                std::printf("R2 weapon %s\n", weaponOn ? "on" : "off");
            }
            if (pressed & TACTILE_BUTTON_OPTIONS) break;
            static uint8_t lastX = 0, lastY = 0;
            if (in.left_x / 16 != lastX / 16 || in.left_y / 16 != lastY / 16) {
                lastX = in.left_x;
                lastY = in.left_y;
                tactile_controller_set_lightbar(pad, in.left_x, 64, in.left_y);
            }
        }
        if (int32_t err = tactile_controller_last_error(pad)) std::fprintf(stderr, "output error: %s\n", tactile_result_string(err));
        frame += std::chrono::microseconds(16667);
        std::this_thread::sleep_until(frame);
    }
    tactile_controller_release(pad);
    tactile_context_destroy(ctx);  // restores neutral state
    return 0;
}
