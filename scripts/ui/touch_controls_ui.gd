class_name TouchControlsUI
extends Control

## Mobile on-screen touch controls:
## - Virtual analog joystick for 8-way / analog movement
## - Touch swipe zone for smooth 3D camera rotation
## - On-screen action buttons: Jump, Sprint, Attack, Pick Up, Perspective, Inventory, Menu, Chat
## - Full multi-touch isolation (independent touch indices)
## - Edge-case and focus-loss handling

signal camera_rotated(relative_delta: Vector2)

const JOYSTICK_MAX_RADIUS := 70.0
const JOYSTICK_DEADZONE := 0.12
const CAMERA_TOUCH_SENSITIVITY := 1.25

# Nodes
@onready var joystick_base: Control = $JoystickZone/JoystickBase
@onready var joystick_knob: Control = $JoystickZone/JoystickBase/Knob
@onready var joystick_zone: Control = $JoystickZone
@onready var camera_touch_zone: Control = $CameraTouchZone
@onready var jump_btn: Button = $ActionButtons/JumpButton
@onready var sprint_btn: Button = $ActionButtons/SprintButton
@onready var attack_btn: Button = $ActionButtons/AttackButton
@onready var pickup_btn: Button = $ActionButtons/PickupButton

# Quick bar nodes
@onready var view_btn: Button = $TopQuickBar/ViewButton
@onready var inv_btn: Button = $TopQuickBar/InventoryButton
@onready var menu_btn: Button = $TopQuickBar/MenuButton
@onready var chat_btn: Button = $TopQuickBar/ChatButton

# State tracking with touch index isolation
var _joystick_touch_index: int = -1
var _joystick_center: Vector2 = Vector2.ZERO
var _joystick_vector: Vector2 = Vector2.ZERO

var _camera_touch_index: int = -1
var _last_camera_touch_pos: Vector2 = Vector2.ZERO

var _is_sprinting: bool = false
var _active_touches: Dictionary = {} # index -> node_or_action

# Simulated action tracking to prevent stuck keys
var _simulated_actions: Array[StringName] = []


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_update_joystick_center()
	resized.connect(_update_joystick_center)

	# Connect PlatformManager signal
	if PlatformManager:
		PlatformManager.touch_controls_toggled.connect(_on_touch_controls_toggled)
		visible = PlatformManager.touch_controls_enabled
	else:
		visible = false

	# Setup buttons
	_setup_button(jump_btn, &"jump", true)
	_setup_button(attack_btn, &"attack", true)
	_setup_button(pickup_btn, &"pickup", true)

	sprint_btn.pressed.connect(_on_sprint_pressed)
	view_btn.pressed.connect(func(): _trigger_instant_action(&"toggle_camera"))
	inv_btn.pressed.connect(func(): _trigger_instant_action(&"inventory"))
	menu_btn.pressed.connect(func(): _trigger_instant_action(&"pause"))
	chat_btn.pressed.connect(func(): _trigger_instant_action(&"toggle_chat"))


func _notification(what: int) -> void:
	# Handle application focus out / pause edge cases
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_PAUSED:
		_reset_all_touch_inputs()


func _on_touch_controls_toggled(enabled: bool) -> void:
	visible = enabled
	if not enabled:
		_reset_all_touch_inputs()


func _update_joystick_center() -> void:
	if joystick_base:
		_joystick_center = joystick_base.size * 0.5
		if joystick_knob:
			joystick_knob.position = _joystick_center - joystick_knob.size * 0.5


func _input(event: InputEvent) -> void:
	if not visible:
		return

	# Handle screen touch (press / release)
	if event is InputEventScreenTouch:
		_handle_screen_touch(event)
	# Handle screen drag
	elif event is InputEventScreenDrag:
		_handle_screen_drag(event)


func _handle_screen_touch(event: InputEventScreenTouch) -> void:
	var touch_pos := event.position

	if event.pressed:
		_active_touches[event.index] = touch_pos

		# Check joystick zone first (left side of screen)
		if _joystick_touch_index == -1 and joystick_zone.get_global_rect().has_point(touch_pos):
			_joystick_touch_index = event.index
			_update_joystick(touch_pos)
			get_viewport().set_input_as_handled()
			return

		# Check camera swipe zone (right side of screen, if not over buttons)
		if _camera_touch_index == -1 and camera_touch_zone.get_global_rect().has_point(touch_pos):
			# Ensure touch is not on any active action button
			if not _is_point_on_any_button(touch_pos):
				_camera_touch_index = event.index
				_last_camera_touch_pos = touch_pos
				get_viewport().set_input_as_handled()
				return

	else: # Touch released
		_active_touches.erase(event.index)

		if event.index == _joystick_touch_index:
			_release_joystick()
			get_viewport().set_input_as_handled()

		if event.index == _camera_touch_index:
			_camera_touch_index = -1
			get_viewport().set_input_as_handled()


func _handle_screen_drag(event: InputEventScreenDrag) -> void:
	if event.index == _joystick_touch_index:
		_update_joystick(event.position)
		get_viewport().set_input_as_handled()

	elif event.index == _camera_touch_index:
		var delta: Vector2 = event.relative
		_apply_camera_rotation(delta)
		get_viewport().set_input_as_handled()


func _update_joystick(touch_global_pos: Vector2) -> void:
	var base_global_center := joystick_base.global_position + _joystick_center
	var offset: Vector2 = touch_global_pos - base_global_center
	var distance := offset.length()

	if distance > JOYSTICK_MAX_RADIUS:
		offset = offset.normalized() * JOYSTICK_MAX_RADIUS

	if joystick_knob:
		joystick_knob.position = (_joystick_center + offset) - (joystick_knob.size * 0.5)

	# Calculate normalized direction vector (-1.0 to 1.0)
	var raw_vector := offset / JOYSTICK_MAX_RADIUS
	if raw_vector.length() < JOYSTICK_DEADZONE:
		_joystick_vector = Vector2.ZERO
	else:
		_joystick_vector = raw_vector

	_apply_movement_actions(_joystick_vector)


func _release_joystick() -> void:
	_joystick_touch_index = -1
	_joystick_vector = Vector2.ZERO
	_reset_joystick_visual()
	_release_action_safe(&"move_left")
	_release_action_safe(&"move_right")
	_release_action_safe(&"move_forward")
	_release_action_safe(&"move_backward")


func _reset_joystick_visual() -> void:
	if joystick_knob and joystick_base:
		joystick_knob.position = _joystick_center - joystick_knob.size * 0.5


func _apply_movement_actions(vec: Vector2) -> void:
	# Analog mapping for Godot Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	# Horizontal (X)
	if vec.x > JOYSTICK_DEADZONE:
		_press_action_safe(&"move_right", vec.x)
		_release_action_safe(&"move_left")
	elif vec.x < -JOYSTICK_DEADZONE:
		_press_action_safe(&"move_left", -vec.x)
		_release_action_safe(&"move_right")
	else:
		_release_action_safe(&"move_left")
		_release_action_safe(&"move_right")

	# Vertical (Y) - In Godot, forward is negative Y in 2D vector
	if vec.y < -JOYSTICK_DEADZONE:
		_press_action_safe(&"move_forward", -vec.y)
		_release_action_safe(&"move_backward")
	elif vec.y > JOYSTICK_DEADZONE:
		_press_action_safe(&"move_backward", vec.y)
		_release_action_safe(&"move_forward")
	else:
		_release_action_safe(&"move_forward")
		_release_action_safe(&"move_backward")


func _apply_camera_rotation(delta: Vector2) -> void:
	var scaled_delta := delta * CAMERA_TOUCH_SENSITIVITY
	camera_rotated.emit(scaled_delta)


func _press_action_safe(action: StringName, strength: float = 1.0) -> void:
	Input.action_press(action, clampf(strength, 0.0, 1.0))
	if not _simulated_actions.has(action):
		_simulated_actions.append(action)


func _release_action_safe(action: StringName) -> void:
	if Input.is_action_pressed(action):
		Input.action_release(action)
	_simulated_actions.erase(action)


func _trigger_instant_action(action: StringName) -> void:
	Input.action_press(action)
	call_deferred("_release_action_safe", action)


func _on_sprint_pressed() -> void:
	_is_sprinting = not _is_sprinting
	if _is_sprinting:
		_press_action_safe(&"shift", 1.0)
		sprint_btn.text = "SPRINT: ON"
		sprint_btn.modulate = Color(0.4, 1.0, 0.4, 1.0)
	else:
		_release_action_safe(&"shift")
		sprint_btn.text = "SPRINT"
		sprint_btn.modulate = Color.WHITE


func _setup_button(btn: Button, action: StringName, is_hold: bool) -> void:
	if not btn:
		return
	if is_hold:
		btn.button_down.connect(func(): _press_action_safe(action, 1.0))
		btn.button_up.connect(func(): _release_action_safe(action))
	else:
		btn.pressed.connect(func(): _trigger_instant_action(action))


func _is_point_on_any_button(point: Vector2) -> bool:
	var buttons = [jump_btn, sprint_btn, attack_btn, pickup_btn, view_btn, inv_btn, menu_btn, chat_btn]
	for btn in buttons:
		if btn and btn.is_visible_in_tree() and btn.get_global_rect().has_point(point):
			return true
	return false


## Clears all simulated inputs and active touches. Called on menu open, disconnect, or focus out.
func _reset_all_touch_inputs() -> void:
	_release_joystick()
	_camera_touch_index = -1
	_active_touches.clear()

	for action in _simulated_actions.duplicate():
		_release_action_safe(action)
	_simulated_actions.clear()

	if _is_sprinting:
		_release_action_safe(&"shift")
		_is_sprinting = false
		if sprint_btn:
			sprint_btn.text = "SPRINT"
			sprint_btn.modulate = Color.WHITE
