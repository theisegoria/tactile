#include "tactile_pad.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>

using namespace godot;

namespace {
PackedByteArray to_bytes(int32_t result, const tactile_trigger_effect &e) {
    PackedByteArray out;
    if (result != TACTILE_OK) return out;
    out.resize(11);
    std::memcpy(out.ptrw(), e.bytes, 11);
    return out;
}
float axis(uint8_t v) { return (static_cast<int>(v) - 128) / 127.5f; }
} // namespace

TactilePad::TactilePad() {
    state.struct_size = sizeof(state);
}

TactilePad::~TactilePad() {
    close_context(false);
}

// The context lives exactly while the node is in the tree: created on every
// enter (not only the first, as _ready would be) and destroyed on every exit,
// so a node that is removed and re-added (reparenting, pooling) keeps working.
void TactilePad::_enter_tree() {
    open_context();
}

void TactilePad::_exit_tree() {
    close_context(true);
}

void TactilePad::open_context() {
    if (ctx) return;
    if (Engine::get_singleton()->is_editor_hint()) return;
    if ((tactile_abi_version() >> 16) != TACTILE_ABI_VERSION_MAJOR) {
        UtilityFunctions::push_error("Tactile: native library ABI mismatch");
        return;
    }
    if (tactile_permission_status() != TACTILE_PERMISSION_GRANTED) tactile_permission_request();
    tactile_options o{};
    o.struct_size = sizeof(o);
    o.mode = exclusive ? TACTILE_MODE_EXCLUSIVE : TACTILE_MODE_SHARED;
    if (tactile_context_create(&o, &ctx) != TACTILE_OK) ctx = nullptr;
}

void TactilePad::close_context(bool notify) {
    if (pad) {
        tactile_controller_release(pad);
        pad = nullptr;
    }
    if (ctx) {
        tactile_context_destroy(ctx); // restores neutral output
        ctx = nullptr;
    }
    const bool had_controller = was_connected;
    std::memset(&state, 0, sizeof(state));
    state.struct_size = sizeof(state);
    previous_buttons = 0;
    pressed_edges = 0;
    was_connected = false;
    if (notify && had_controller) emit_signal("controller_disconnected");
}

namespace {
// Returns a retained handle to the first controller that is delivering input
// (filling `s`), or nullptr. Non-blocking: get_input only copies a snapshot.
tactile_controller *find_reporting(tactile_context *ctx, tactile_controller *skip, tactile_input_state &s) {
    const int32_t n = tactile_context_controller_count(ctx);
    for (int32_t i = 0; i < n; ++i) {
        tactile_controller *c = nullptr;
        if (tactile_context_get_controller(ctx, i, &c) != TACTILE_OK || !c) continue;
        s.struct_size = sizeof(s);
        if (c != skip && tactile_controller_get_input(c, &s) == TACTILE_OK) return c;
        tactile_controller_release(c);
    }
    return nullptr;
}
} // namespace

void TactilePad::_process(double) {
    if (!ctx) return;
    bool connected = false;
    if (pad) {
        state.struct_size = sizeof(state);
        connected = tactile_controller_get_input(pad, &state) == TACTILE_OK;
    }
    bool switched = false;
    if (!connected) {
        // The context lists every controller it has ever seen, so index 0 may be
        // a pad that is gone for good. Follow whichever one is reporting.
        if (tactile_controller *live = find_reporting(ctx, pad, state)) {
            switched = pad != nullptr;
            if (pad) tactile_controller_release(pad);
            pad = live;
            connected = true;
        } else if (!pad && tactile_context_controller_count(ctx) > 0) {
            // Nothing reporting yet: hold the first one so output calls reach it.
            tactile_context_get_controller(ctx, 0, &pad);
        }
    }
    if (switched && was_connected) {
        emit_signal("controller_disconnected");
        was_connected = false;
    }
    if (connected != was_connected) {
        was_connected = connected;
        emit_signal(connected ? "controller_connected" : "controller_disconnected");
    }
    uint32_t b = connected ? state.buttons : 0;
    pressed_edges = b & ~previous_buttons;
    previous_buttons = b;
    if (!connected) {
        std::memset(&state, 0, sizeof(state));
        state.struct_size = sizeof(state);
    }
}

bool TactilePad::is_connected_pad() const { return was_connected; }

Dictionary TactilePad::get_info() const {
    Dictionary d;
    if (!pad) return d;
    tactile_controller_info i{};
    i.struct_size = sizeof(i);
    if (tactile_controller_get_info(pad, &i) != TACTILE_OK) return d;
    d["model"] = i.model == TACTILE_MODEL_DUALSENSE_EDGE ? "DualSense Edge" : "DualSense";
    d["transport"] = i.transport == TACTILE_TRANSPORT_USB ? "usb" : "bluetooth";
    d["address"] = String(i.address);
    d["firmware_version"] = (int64_t)i.firmware_version;
    d["update_version"] = String::num_int64(i.update_version >> 8) + "." + String::num_int64(i.update_version & 0xFF).pad_zeros(2);
    return d;
}

Vector2 TactilePad::get_left_stick() const { return was_connected ? Vector2(axis(state.left_x), axis(state.left_y)) : Vector2(); }
Vector2 TactilePad::get_right_stick() const { return was_connected ? Vector2(axis(state.right_x), axis(state.right_y)) : Vector2(); }

int64_t TactilePad::set_lightbar(const Color &c) {
    if (!pad) return TACTILE_ERR_NOT_CONNECTED;
    return tactile_controller_set_lightbar(pad, (uint8_t)c.get_r8(), (uint8_t)c.get_g8(), (uint8_t)c.get_b8());
}
int64_t TactilePad::set_player_leds(int64_t mask) { return pad ? tactile_controller_set_player_leds(pad, (uint8_t)mask) : TACTILE_ERR_NOT_CONNECTED; }
int64_t TactilePad::set_mute_led(int64_t mode) { return pad ? tactile_controller_set_mute_led(pad, (int32_t)mode) : TACTILE_ERR_NOT_CONNECTED; }
int64_t TactilePad::set_rumble(float l, float r) {
    if (!pad) return TACTILE_ERR_NOT_CONNECTED;
    auto clamp8 = [](float v) { return (uint8_t)(v <= 0 ? 0 : v >= 1 ? 255 : v * 255.0f); };
    return tactile_controller_set_rumble(pad, clamp8(l), clamp8(r));
}
int64_t TactilePad::set_trigger(int64_t side, const PackedByteArray &effect) {
    if (!pad) return TACTILE_ERR_NOT_CONNECTED;
    if (effect.size() != 11) return TACTILE_ERR_INVALID_ARGUMENT;
    tactile_trigger_effect e{};
    std::memcpy(e.bytes, effect.ptr(), 11);
    return tactile_controller_set_trigger(pad, (int32_t)side, &e);
}
int64_t TactilePad::neutralize() { return pad ? tactile_controller_neutralize(pad) : TACTILE_ERR_NOT_CONNECTED; }

int64_t TactilePad::play_haptic(int64_t effect, float intensity, int64_t side) {
    return pad ? tactile_haptics_play(pad, (int32_t)effect, intensity, (int32_t)side) : TACTILE_ERR_NOT_CONNECTED;
}
int64_t TactilePad::write_pcm(const PackedFloat32Array &s, int64_t channels, double rate) {
    if (!pad) return TACTILE_ERR_NOT_CONNECTED;
    if (channels <= 0) return TACTILE_ERR_INVALID_ARGUMENT;
    return tactile_haptics_write_pcm(pad, s.ptr(), (int32_t)(s.size() / channels), (int32_t)channels, rate);
}

PackedByteArray TactilePad::trigger_off() { tactile_trigger_effect e{}; tactile_trigger_off(&e); return to_bytes(TACTILE_OK, e); }
PackedByteArray TactilePad::trigger_feedback(int64_t p, int64_t s) { tactile_trigger_effect e{}; return to_bytes(tactile_trigger_feedback((int32_t)p, (int32_t)s, &e), e); }
PackedByteArray TactilePad::trigger_weapon(int64_t a, int64_t b, int64_t s) { tactile_trigger_effect e{}; return to_bytes(tactile_trigger_weapon((int32_t)a, (int32_t)b, (int32_t)s, &e), e); }
PackedByteArray TactilePad::trigger_vibration(int64_t p, int64_t a, int64_t f) { tactile_trigger_effect e{}; return to_bytes(tactile_trigger_vibration((int32_t)p, (int32_t)a, (int32_t)f, &e), e); }
PackedByteArray TactilePad::trigger_slope_feedback(int64_t sp, int64_t ep, int64_t ss, int64_t es) { tactile_trigger_effect e{}; return to_bytes(tactile_trigger_slope_feedback((int32_t)sp, (int32_t)ep, (int32_t)ss, (int32_t)es, &e), e); }
PackedByteArray TactilePad::trigger_bow(int64_t a, int64_t b, int64_t s, int64_t n) { tactile_trigger_effect e{}; return to_bytes(tactile_trigger_bow((int32_t)a, (int32_t)b, (int32_t)s, (int32_t)n, &e), e); }
PackedByteArray TactilePad::trigger_galloping(int64_t a, int64_t b, int64_t f1, int64_t f2, int64_t f) { tactile_trigger_effect e{}; return to_bytes(tactile_trigger_galloping((int32_t)a, (int32_t)b, (int32_t)f1, (int32_t)f2, (int32_t)f, &e), e); }
PackedByteArray TactilePad::trigger_machine(int64_t a, int64_t b, int64_t x, int64_t y, int64_t f, int64_t p) { tactile_trigger_effect e{}; return to_bytes(tactile_trigger_machine((int32_t)a, (int32_t)b, (int32_t)x, (int32_t)y, (int32_t)f, (int32_t)p, &e), e); }

void TactilePad::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_exclusive", "exclusive"), &TactilePad::set_exclusive);
    ClassDB::bind_method(D_METHOD("get_exclusive"), &TactilePad::get_exclusive);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "exclusive"), "set_exclusive", "get_exclusive");

    ClassDB::bind_method(D_METHOD("is_connected_pad"), &TactilePad::is_connected_pad);
    ClassDB::bind_method(D_METHOD("get_info"), &TactilePad::get_info);
    ClassDB::bind_method(D_METHOD("get_buttons"), &TactilePad::get_buttons);
    ClassDB::bind_method(D_METHOD("is_pressed", "button_mask"), &TactilePad::is_pressed);
    ClassDB::bind_method(D_METHOD("is_just_pressed", "button_mask"), &TactilePad::is_just_pressed);
    ClassDB::bind_method(D_METHOD("get_left_stick"), &TactilePad::get_left_stick);
    ClassDB::bind_method(D_METHOD("get_right_stick"), &TactilePad::get_right_stick);
    ClassDB::bind_method(D_METHOD("get_l2"), &TactilePad::get_l2);
    ClassDB::bind_method(D_METHOD("get_r2"), &TactilePad::get_r2);
    ClassDB::bind_method(D_METHOD("get_gyro"), &TactilePad::get_gyro);
    ClassDB::bind_method(D_METHOD("get_accel"), &TactilePad::get_accel);
    ClassDB::bind_method(D_METHOD("get_battery_percent"), &TactilePad::get_battery_percent);

    ClassDB::bind_method(D_METHOD("set_lightbar", "color"), &TactilePad::set_lightbar);
    ClassDB::bind_method(D_METHOD("set_player_leds", "mask"), &TactilePad::set_player_leds);
    ClassDB::bind_method(D_METHOD("set_mute_led", "mode"), &TactilePad::set_mute_led);
    ClassDB::bind_method(D_METHOD("set_rumble", "left", "right"), &TactilePad::set_rumble);
    ClassDB::bind_method(D_METHOD("set_trigger", "side", "effect"), &TactilePad::set_trigger);
    ClassDB::bind_method(D_METHOD("neutralize"), &TactilePad::neutralize);
    ClassDB::bind_method(D_METHOD("play_haptic", "effect", "intensity", "side"), &TactilePad::play_haptic);
    ClassDB::bind_method(D_METHOD("write_pcm", "interleaved", "channels", "sample_rate"), &TactilePad::write_pcm);

    ClassDB::bind_static_method("TactilePad", D_METHOD("trigger_off"), &TactilePad::trigger_off);
    ClassDB::bind_static_method("TactilePad", D_METHOD("trigger_feedback", "position", "strength"), &TactilePad::trigger_feedback);
    ClassDB::bind_static_method("TactilePad", D_METHOD("trigger_weapon", "start", "end", "strength"), &TactilePad::trigger_weapon);
    ClassDB::bind_static_method("TactilePad", D_METHOD("trigger_vibration", "position", "amplitude", "frequency"), &TactilePad::trigger_vibration);
    ClassDB::bind_static_method("TactilePad", D_METHOD("trigger_slope_feedback", "start_position", "end_position", "start_strength", "end_strength"), &TactilePad::trigger_slope_feedback);
    ClassDB::bind_static_method("TactilePad", D_METHOD("trigger_bow", "start", "end", "strength", "snap_force"), &TactilePad::trigger_bow);
    ClassDB::bind_static_method("TactilePad", D_METHOD("trigger_galloping", "start", "end", "first_foot", "second_foot", "frequency"), &TactilePad::trigger_galloping);
    ClassDB::bind_static_method("TactilePad", D_METHOD("trigger_machine", "start", "end", "amplitude_a", "amplitude_b", "frequency", "period"), &TactilePad::trigger_machine);

    ADD_SIGNAL(MethodInfo("controller_connected"));
    ADD_SIGNAL(MethodInfo("controller_disconnected"));

    BIND_CONSTANT(TACTILE_TRIGGER_LEFT);
    BIND_CONSTANT(TACTILE_TRIGGER_RIGHT);
    BIND_CONSTANT(TACTILE_HAPTIC_CLICK);
    BIND_CONSTANT(TACTILE_HAPTIC_DETENT);
    BIND_CONSTANT(TACTILE_HAPTIC_TEXTURE);
    BIND_CONSTANT(TACTILE_HAPTIC_IMPACT);
    BIND_CONSTANT(TACTILE_HAPTIC_LEFT);
    BIND_CONSTANT(TACTILE_HAPTIC_RIGHT);
    BIND_CONSTANT(TACTILE_HAPTIC_BOTH);
    ClassDB::bind_integer_constant(get_class_static(), "", "BUTTON_CROSS", TACTILE_BUTTON_CROSS);
    ClassDB::bind_integer_constant(get_class_static(), "", "BUTTON_CIRCLE", TACTILE_BUTTON_CIRCLE);
    ClassDB::bind_integer_constant(get_class_static(), "", "BUTTON_SQUARE", TACTILE_BUTTON_SQUARE);
    ClassDB::bind_integer_constant(get_class_static(), "", "BUTTON_TRIANGLE", TACTILE_BUTTON_TRIANGLE);
    ClassDB::bind_integer_constant(get_class_static(), "", "BUTTON_OPTIONS", TACTILE_BUTTON_OPTIONS);
    ClassDB::bind_integer_constant(get_class_static(), "", "BUTTON_PADDLE_LEFT", TACTILE_BUTTON_PADDLE_LEFT);
    ClassDB::bind_integer_constant(get_class_static(), "", "BUTTON_PADDLE_RIGHT", TACTILE_BUTTON_PADDLE_RIGHT);
    ClassDB::bind_integer_constant(get_class_static(), "", "BUTTON_FN_LEFT", TACTILE_BUTTON_FN_LEFT);
    ClassDB::bind_integer_constant(get_class_static(), "", "BUTTON_FN_RIGHT", TACTILE_BUTTON_FN_RIGHT);
}
