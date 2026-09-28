class_name MainMenuUI
extends Control

signal host_pressed(nickname: String, skin: String, address: String)
signal join_pressed(nickname: String, skin: String, address: String)
signal quit_pressed

const SKIN_OPTIONS: Array[String] = ["Blue", "Yellow", "Green", "Red"]
const SAFE_AREA_MARGIN := 24.0

@onready var skin_input: OptionButton = $MainContainer/MainMenu/Option2/SkinInput
@onready var nick_input: LineEdit = $MainContainer/MainMenu/Option1/NickInput
@onready var address_input: LineEdit = $MainContainer/MainMenu/Option3/AddressInput
@onready var main_container: VBoxContainer = $MainContainer

# Room Code & Status UI
@onready var host_code_container: HBoxContainer = $MainContainer/MainMenu/HostCodeContainer
@onready var host_code_label: Label = $MainContainer/MainMenu/HostCodeContainer/HostCodeLabel
@onready var copy_code_btn: Button = $MainContainer/MainMenu/HostCodeContainer/CopyCodeButton

@onready var status_label: Label = $MainContainer/MainMenu/StatusLabel
@onready var platform_label: Label = $MainContainer/MainMenu/PlatformContainer/PlatformLabel
@onready var touch_toggle_btn: Button = $MainContainer/MainMenu/PlatformContainer/TouchToggleBtn


func _ready() -> void:
	skin_input.clear()
	for skin_name in SKIN_OPTIONS:
		skin_input.add_item(skin_name)
	skin_input.select(0)

	resized.connect(_update_responsive_layout)
	call_deferred("_update_responsive_layout")

	# Connect Network signals for status and codes
	if Network:
		Network.room_code_generated.connect(_on_room_code_generated)
		Network.connection_status_changed.connect(_on_connection_status_changed)
		Network.connection_failed_with_details.connect(_on_connection_failed_with_details)

	if PlatformManager:
		PlatformManager.platform_detected.connect(_on_platform_detected)
		PlatformManager.touch_controls_toggled.connect(_on_touch_toggled)
		_refresh_platform_ui()

	if copy_code_btn:
		copy_code_btn.pressed.connect(_on_copy_code_pressed)

	if touch_toggle_btn:
		touch_toggle_btn.pressed.connect(_on_touch_toggle_pressed)

	_clear_status()
	if host_code_container:
		host_code_container.visible = false


func _refresh_platform_ui() -> void:
	if not PlatformManager:
		return
	if platform_label:
		platform_label.text = PlatformManager.get_platform_badge_text()
	if touch_toggle_btn:
		touch_toggle_btn.text = "Touch Controls: " + ("ON" if PlatformManager.touch_controls_enabled else "OFF")


func _on_platform_detected(_p_name: String, _is_mobile: bool, _is_touch: bool) -> void:
	_refresh_platform_ui()


func _on_touch_toggled(_enabled: bool) -> void:
	_refresh_platform_ui()


func _on_touch_toggle_pressed() -> void:
	if PlatformManager:
		PlatformManager.toggle_touch_controls()


func _on_host_pressed() -> void:
	_clear_status()
	var nickname = nick_input.text.strip_edges()
	var skin = get_skin()
	var address = address_input.text.strip_edges()
	show_status("Hosting room...", false)
	host_pressed.emit(nickname, skin, address)


func _on_join_pressed() -> void:
	_clear_status()
	var nickname = nick_input.text.strip_edges()
	var skin = get_skin()
	var address = address_input.text.strip_edges()

	if address.is_empty():
		show_status("Please enter a Join Code or Server Address.", true)
		return

	show_status("Connecting...", false)
	join_pressed.emit(nickname, skin, address)


func _on_room_code_generated(code: String) -> void:
	if host_code_container and host_code_label:
		host_code_container.visible = true
		host_code_label.text = "Room Code: " + code
		show_status("Hosting session! Share Room Code: " + code, false)


func _on_copy_code_pressed() -> void:
	if Network and not Network.current_room_code.is_empty():
		DisplayServer.clipboard_set(Network.current_room_code)
		show_status("Copied Room Code '%s' to clipboard!" % Network.current_room_code, false)
	elif not address_input.text.is_empty():
		DisplayServer.clipboard_set(address_input.text.strip_edges())
		show_status("Copied address to clipboard!", false)


func _on_connection_status_changed(message: String, is_warning: bool) -> void:
	show_status(message, is_warning)


func _on_connection_failed_with_details(error_message: String) -> void:
	show_status(error_message, true)


func show_status(message: String, is_error: bool) -> void:
	if not status_label:
		return
	status_label.text = message
	if is_error:
		status_label.modulate = Color(1.0, 0.45, 0.45, 1.0)
	else:
		status_label.modulate = Color(0.55, 0.9, 0.6, 1.0)


func _clear_status() -> void:
	if status_label:
		status_label.text = ""


func _on_quit_pressed() -> void:
	quit_pressed.emit()


func show_menu() -> void:
	show()
	_refresh_platform_ui()
	call_deferred("_update_responsive_layout")


func hide_menu() -> void:
	hide()


func is_menu_visible() -> bool:
	return visible


func _update_responsive_layout() -> void:
	if not main_container:
		return
	var available_size := Vector2(
		maxf(1.0, size.x - SAFE_AREA_MARGIN * 2.0), maxf(1.0, size.y - SAFE_AREA_MARGIN * 2.0)
	)
	var content_size := main_container.get_combined_minimum_size()
	if content_size.x <= 0.0 or content_size.y <= 0.0:
		return
	var scale_factor := minf(1.0, minf(available_size.x / content_size.x, available_size.y / content_size.y))
	main_container.pivot_offset = main_container.size * 0.5
	main_container.scale = Vector2.ONE * scale_factor


func get_skin() -> String:
	return skin_input.get_item_text(skin_input.selected).to_lower()
