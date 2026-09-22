extends Node
# Cross = haptic click, Circle = toggle R2 weapon, left stick = lightbar.

@onready var pad: TactilePad = $Pad
@onready var label: Label = $Label
var weapon_on := false

func _ready() -> void:
	pad.controller_connected.connect(func(): label.text = "Connected: %s" % pad.get_info())
	pad.controller_disconnected.connect(func(): label.text = "Disconnected")

func _process(_delta: float) -> void:
	if not pad.is_connected_pad():
		return
	if pad.is_just_pressed(TactilePad.BUTTON_CROSS):
		pad.play_haptic(TactilePad.TACTILE_HAPTIC_CLICK, 1.0, TactilePad.TACTILE_HAPTIC_BOTH)
	if pad.is_just_pressed(TactilePad.BUTTON_CIRCLE):
		weapon_on = not weapon_on
		var effect := TactilePad.trigger_weapon(3, 6, 8) if weapon_on else TactilePad.trigger_off()
		pad.set_trigger(TactilePad.TACTILE_TRIGGER_RIGHT, effect)
	var s := pad.get_left_stick()
	pad.set_lightbar(Color((s.x + 1) / 2, 0.25, (s.y + 1) / 2))
	label.text = "L %s  R %s  L2 %.2f  R2 %.2f  gyro %s" % [s, pad.get_right_stick(), pad.get_l2(), pad.get_r2(), pad.get_gyro()]
