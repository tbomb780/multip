class_name RoomCodeHUD
extends CanvasLayer

## In-Game Room Code & Share HUD Overlay
## Displays current room code with quick-action Copy Code and Share buttons.
## Supports Web Share API (native share drawer on phones/tablets) and clipboard fallback.

@onready var panel_container: PanelContainer = $RootMargin/PanelContainer
@onready var full_bar: HBoxContainer = $RootMargin/PanelContainer/FullBar
@onready var compact_bar: HBoxContainer = $RootMargin/PanelContainer/CompactBar
@onready var role_badge: Label = $RootMargin/PanelContainer/FullBar/RoleBadge
@onready var code_label: Label = $RootMargin/PanelContainer/FullBar/CodeLabel
@onready var compact_code_label: Label = $RootMargin/PanelContainer/CompactBar/CompactCodeLabel
@onready var copy_button: Button = $RootMargin/PanelContainer/FullBar/CopyButton
@onready var share_button: Button = $RootMargin/PanelContainer/FullBar/ShareButton
@onready var collapse_button: Button = $RootMargin/PanelContainer/FullBar/CollapseButton
@onready var expand_button: Button = $RootMargin/PanelContainer/CompactBar/ExpandButton

var current_code: String = ""
var is_collapsed: bool = false
var _copy_reset_timer: SceneTreeTimer = null
var _share_reset_timer: SceneTreeTimer = null


func _ready() -> void:
	visible = false
	if full_bar and compact_bar:
		full_bar.visible = true
		compact_bar.visible = false

	if copy_button:
		copy_button.pressed.connect(_on_copy_pressed)
	if share_button:
		share_button.pressed.connect(_on_share_pressed)
	if collapse_button:
		collapse_button.pressed.connect(_on_collapse_pressed)
	if expand_button:
		expand_button.pressed.connect(_on_expand_pressed)

	if Network:
		Network.room_code_generated.connect(_on_room_code_updated)
		Network.room_joined.connect(_on_room_code_updated)
		Network.direct_code_generated.connect(_on_direct_code_updated)
		Network.server_disconnected.connect(_on_disconnected)


func show_hud(code: String, is_host: bool = false) -> void:
	current_code = code.strip_edges().to_upper()
	if current_code.is_empty():
		hide_hud()
		return

	if code_label:
		code_label.text = current_code
	if compact_code_label:
		compact_code_label.text = current_code
	if role_badge:
		role_badge.text = "HOST" if is_host else "ROOM"
		role_badge.modulate = Color(1.0, 0.85, 0.3) if is_host else Color(0.4, 0.85, 1.0)

	visible = true


func hide_hud() -> void:
	visible = false
	current_code = ""


func _on_room_code_updated(code: String) -> void:
	var is_host = Network.is_room_host if Network else false
	show_hud(code, is_host)


func _on_direct_code_updated(code: String) -> void:
	if current_code.is_empty():
		show_hud(code, true)


func _on_disconnected() -> void:
	hide_hud()


func _on_copy_pressed() -> void:
	if current_code.is_empty():
		return

	DisplayServer.clipboard_set(current_code)

	if copy_button:
		copy_button.text = "✓ Copied!"
		copy_button.modulate = Color(0.5, 1.0, 0.6)
		_copy_reset_timer = get_tree().create_timer(2.0)
		_copy_reset_timer.timeout.connect(func():
			if is_instance_valid(copy_button):
				copy_button.text = "📋 Copy"
				copy_button.modulate = Color.WHITE
		)


func _on_share_pressed() -> void:
	if current_code.is_empty():
		return

	var share_text := "Join my multiplayer room in Godot 3D! Room Code: %s" % current_code
	var share_url := ""

	# Check if running in Web browser to use Web Share API & URL parameter
	if OS.has_feature("web"):
		var js_code := """
		(function() {
			var code = '%s';
			var url = window.location.origin + window.location.pathname + '?room=' + code;
			var shareData = {
				title: 'Godot 3D Multiplayer',
				text: 'Join my room code: ' + code,
				url: url
			};
			if (navigator.share) {
				navigator.share(shareData).catch(function(err) {});
			} else if (navigator.clipboard) {
				navigator.clipboard.writeText(url);
			}
		})()
		""" % current_code
		JavaScriptBridge.eval(js_code)
		share_url = current_code
	else:
		# Native desktop or mobile without JS bridge
		var render_url = Network.get_cloud_server_url() if Network else ""
		if not render_url.is_empty() and render_url.begins_with("wss://"):
			var web_http = render_url.replace("wss://", "https://")
			share_url = "%s/?room=%s" % [web_http, current_code]
		else:
			share_url = current_code

		DisplayServer.clipboard_set(share_text + "\n" + share_url)

	if share_button:
		share_button.text = "✓ Shared!"
		share_button.modulate = Color(0.4, 0.9, 1.0)
		_share_reset_timer = get_tree().create_timer(2.0)
		_share_reset_timer.timeout.connect(func():
			if is_instance_valid(share_button):
				share_button.text = "🔗 Share"
				share_button.modulate = Color.WHITE
		)


func _on_collapse_pressed() -> void:
	is_collapsed = true
	if full_bar and compact_bar:
		full_bar.visible = false
		compact_bar.visible = true


func _on_expand_pressed() -> void:
	is_collapsed = false
	if full_bar and compact_bar:
		full_bar.visible = true
		compact_bar.visible = false
