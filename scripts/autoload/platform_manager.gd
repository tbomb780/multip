extends Node

## Autoload: PlatformManager
## Handles runtime platform detection, touchscreen capability detection,
## network protocol constraints, and platform-specific edge cases.

signal platform_detected(platform_name: String, is_mobile: bool, is_touch: bool)
signal touch_controls_toggled(enabled: bool)

enum PlatformType {
	WINDOWS,
	MACOS,
	LINUX,
	ANDROID,
	IOS,
	WEB,
	UNKNOWN
}

var current_platform: PlatformType = PlatformType.UNKNOWN
var platform_name: String = "Unknown"
var is_mobile: bool = false
var is_web: bool = false
var is_desktop: bool = false
var is_touch_device: bool = false
var touch_controls_enabled: bool = false

# Edge case tracking
var is_touch_simulated: bool = false
var has_physical_keyboard: bool = true


func _ready() -> void:
	_detect_platform()
	_configure_platform_settings()


func _detect_platform() -> void:
	var os_name := OS.get_name().to_lower()
	var is_browser := OS.has_feature("web")

	if is_browser:
		is_web = true
		current_platform = PlatformType.WEB
		# Detect mobile web (e.g. Chrome on Android or Safari on iOS)
		if OS.has_feature("web_android") or OS.has_feature("android"):
			is_mobile = true
			platform_name = "Web (Android)"
		elif OS.has_feature("web_ios") or OS.has_feature("ios"):
			is_mobile = true
			platform_name = "Web (iOS)"
		else:
			platform_name = "Web (HTML5)"
	elif os_name == "android" or OS.has_feature("android"):
		current_platform = PlatformType.ANDROID
		is_mobile = true
		platform_name = "Android"
	elif os_name == "ios" or OS.has_feature("ios"):
		current_platform = PlatformType.IOS
		is_mobile = true
		platform_name = "iOS"
	elif os_name == "windows" or OS.has_feature("windows"):
		current_platform = PlatformType.WINDOWS
		is_desktop = true
		platform_name = "Windows"
	elif os_name == "macos" or OS.has_feature("macos") or OS.has_feature("osx"):
		current_platform = PlatformType.MACOS
		is_desktop = true
		platform_name = "macOS"
	elif os_name in ["linux", "freebsd", "netbsd", "openbsd"] or OS.has_feature("linux"):
		current_platform = PlatformType.LINUX
		is_desktop = true
		platform_name = "Linux"
	else:
		current_platform = PlatformType.UNKNOWN
		platform_name = OS.get_name()
		if OS.has_feature("mobile"):
			is_mobile = true
		elif OS.has_feature("pc"):
			is_desktop = true

	# Touchscreen capability check
	is_touch_device = DisplayServer.is_touchscreen_available() or is_mobile

	# If mobile or touchscreen, enable touch controls by default
	touch_controls_enabled = is_mobile or is_touch_device

	# Check for physical keyboard hint
	if is_mobile:
		has_physical_keyboard = false
	else:
		has_physical_keyboard = true

	print("[PlatformManager] Detected platform: %s | Mobile: %s | Web: %s | Touchscreen: %s | TouchControls: %s" % [
		platform_name, is_mobile, is_web, is_touch_device, touch_controls_enabled
	])

	platform_detected.emit(platform_name, is_mobile, is_touch_device)


func _configure_platform_settings() -> void:
	# On mobile touch devices, mouse emulation can create jitter or unwanted cursor locking.
	if is_mobile:
		# Ensure mouse cursor doesn't force hardware capture on mobile
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func set_touch_controls_enabled(enabled: bool) -> void:
	touch_controls_enabled = enabled
	touch_controls_toggled.emit(touch_controls_enabled)


func toggle_touch_controls() -> bool:
	set_touch_controls_enabled(not touch_controls_enabled)
	return touch_controls_enabled


func can_use_raw_udp() -> bool:
	# Web exports CANNOT use raw UDP (ENet). Browsers restrict socket access to WebSockets or WebRTC.
	return not is_web


func should_lock_mouse() -> bool:
	# On mobile or active touch devices, do not lock/capture mouse mode.
	if is_mobile or (is_touch_device and touch_controls_enabled):
		return false
	return true


## Validates an address string against platform constraints.
## Returns Dictionary with keys: "valid" (bool), "sanitized" (String), "warning" (String), "error" (String)
func validate_address_for_platform(address: String) -> Dictionary:
	var clean := address.strip_edges()
	var result := {
		"valid": true,
		"sanitized": clean,
		"warning": "",
		"error": ""
	}

	if clean.is_empty():
		result["valid"] = false
		result["error"] = "Address or Join Code cannot be empty."
		return result

	# Web platform constraints:
	if is_web:
		if clean.begins_with("enet://"):
			result["valid"] = false
			result["error"] = "Web browsers do not support ENet (UDP). Please use WebSocket (wss://) or WebRTC."
			return result

		# Check for insecure ws:// on web (browsers on HTTPS block unencrypted ws://)
		if clean.begins_with("ws://") and not clean.begins_with("ws://127.0.0.1") and not clean.begins_with("ws://localhost"):
			result["warning"] = "Web browsers may block unencrypted ws:// over HTTPS. If connection fails, use wss://"
			result["sanitized"] = "wss://" + clean.trim_prefix("ws://")

	return result


func get_platform_badge_text() -> String:
	var text := "Platform: " + platform_name
	if touch_controls_enabled:
		text += " • Touch Mode: ON"
	elif is_mobile:
		text += " • Mobile"
	elif is_web:
		text += " • Web (WSS/WebRTC)"
	else:
		text += " • Keyboard/Mouse"
	return text
