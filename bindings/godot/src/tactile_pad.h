// Godot 4 GDExtension node over the Tactile C ABI.
#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "tactile.h"

namespace godot {

class TactilePad : public Node {
    GDCLASS(TactilePad, Node)

public:
    TactilePad();
    ~TactilePad() override;

    void _ready() override;
    void _process(double delta) override;
    void _exit_tree() override;

    // Configuration (set before the node enters the tree).
    void set_exclusive(bool v) { exclusive = v; }
    bool get_exclusive() const { return exclusive; }

    // State
    bool is_connected_pad() const;
    Dictionary get_info() const;
    int64_t get_buttons() const { return state.buttons; }
    bool is_pressed(int64_t button_mask) const { return (state.buttons & (uint32_t)button_mask) != 0; }
    bool is_just_pressed(int64_t button_mask) const { return (pressed_edges & (uint32_t)button_mask) != 0; }
    Vector2 get_left_stick() const;   // -1..1, y down
    Vector2 get_right_stick() const;
    float get_l2() const { return state.l2 / 255.0f; }
    float get_r2() const { return state.r2 / 255.0f; }
    Vector3 get_gyro() const { return Vector3(state.gyro_dps[0], state.gyro_dps[1], state.gyro_dps[2]); }
    Vector3 get_accel() const { return Vector3(state.accel_g[0], state.accel_g[1], state.accel_g[2]); }
    int64_t get_battery_percent() const { return state.battery_percent; }

    // Output (non-blocking)
    int64_t set_lightbar(const Color &color);
    int64_t set_player_leds(int64_t mask);
    int64_t set_mute_led(int64_t mode);
    int64_t set_rumble(float left, float right);
    int64_t set_trigger(int64_t side, const PackedByteArray &effect);
    int64_t neutralize();

    // Haptics
    int64_t play_haptic(int64_t effect, float intensity, int64_t side);
    int64_t write_pcm(const PackedFloat32Array &interleaved, int64_t channels, double sample_rate);

    // Trigger effect builders → 11-byte PackedByteArray (empty on invalid parameters)
    static PackedByteArray trigger_off();
    static PackedByteArray trigger_feedback(int64_t position, int64_t strength);
    static PackedByteArray trigger_weapon(int64_t start, int64_t end, int64_t strength);
    static PackedByteArray trigger_vibration(int64_t position, int64_t amplitude, int64_t frequency);
    static PackedByteArray trigger_slope_feedback(int64_t sp, int64_t ep, int64_t ss, int64_t es);
    static PackedByteArray trigger_bow(int64_t start, int64_t end, int64_t strength, int64_t snap);
    static PackedByteArray trigger_galloping(int64_t start, int64_t end, int64_t foot1, int64_t foot2, int64_t freq);
    static PackedByteArray trigger_machine(int64_t start, int64_t end, int64_t a, int64_t b, int64_t freq, int64_t period);

protected:
    static void _bind_methods();

private:
    tactile_context *ctx = nullptr;
    tactile_controller *pad = nullptr;
    tactile_input_state state{};
    uint32_t previous_buttons = 0;
    uint32_t pressed_edges = 0;
    bool exclusive = false;
    bool was_connected = false;
};

} // namespace godot
