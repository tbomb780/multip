extends Node

## Autoload: Network
## Robust multi-tier multiplayer system with automatic fallback:
## Tier 1: WebRTC Peer-to-Peer with Room Codes (Approach C)
## Tier 2: Dedicated Cloud Server on Render.com (WebSocket / WSS) (Approach A)
## Tier 3: Direct LAN / Local Host Connection (WebSocket or ENet) (Approach B)

signal player_connected(peer_id: int, player_info: Dictionary)
signal server_disconnected
signal connection_status_changed(message: String, is_warning: bool)
signal connection_failed_with_details(error_message: String)
signal room_code_generated(room_code: String)
signal direct_code_generated(code: String)

enum ConnectionTier {
	TIER_1_WEBRTC,
	TIER_2_RENDER_CLOUD,
	TIER_3_DIRECT_LAN
}

const SERVER_ADDRESS: String = "127.0.0.1"
const SERVER_PORT: int = 8080
const MAX_PLAYERS: int = 10
const MAX_NICK_LENGTH := 24
const MAX_ADDRESS_LENGTH := 253

# Readable alphabet excluding ambiguous characters (0, O, 1, I)
const ROOM_CODE_ALPHABET := "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

# Default Cloud URLs (can be overridden by environment variables)
const DEFAULT_RENDER_URL: String = "wss://godot-multiplayer-server.onrender.com"
const DEFAULT_SIGNALING_URL: String = "wss://godot-webrtc-signaling.onrender.com"

var players: Dictionary = {}
var player_info: Dictionary = {"nick": "host", "skin": Character.SkinColor.BLUE}
var _session_active := false

# Room management
var current_room_code: String = ""
var current_direct_code: String = ""
var is_room_host: bool = false
var server_rooms: Dictionary = {} # room_code -> Array of peer_ids

# Multi-Tier Fallback Cascade state
var is_cascade_active: bool = false
var current_tier: ConnectionTier = ConnectionTier.TIER_1_WEBRTC
var _cascade_nickname: String = ""
var _cascade_skin: String = ""
var _cascade_room_code: String = ""
var _cascade_direct_ip: String = ""
var _cascade_error_log: Array[String] = []

# Watchdogs for timeouts & cold starts
var _connecting := false
var _cold_start_timer: Timer = null
var _timeout_timer: Timer = null
var _webrtc_ice_timer: Timer = null

# WebRTC Signaling Client (Approach C)
const WebRTCSignalingClientScript = preload("res://scripts/network/webrtc_signaling_client.gd")
var webrtc_client: Node = null
var _is_webrtc_mode: bool = false


func _ready() -> void:
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.peer_disconnected.connect(_on_player_disconnected)
	multiplayer.peer_connected.connect(_on_player_connected)
	multiplayer.connected_to_server.connect(_on_connected_ok)

	_setup_webrtc_client()
	_setup_watchdog_timers()


func _setup_webrtc_client() -> void:
	webrtc_client = WebRTCSignalingClientScript.new()
	webrtc_client.name = "WebRTCSignalingClient"
	add_child(webrtc_client)

	webrtc_client.room_created.connect(_on_webrtc_room_created)
	webrtc_client.room_joined.connect(_on_webrtc_room_joined)
	webrtc_client.signaling_error.connect(_on_webrtc_signaling_error)
	webrtc_client.peer_connected.connect(func(peer_id): _on_webrtc_peer_connected(peer_id))


func _setup_watchdog_timers() -> void:
	_cold_start_timer = Timer.new()
	_cold_start_timer.one_shot = true
	_cold_start_timer.wait_time = 4.5
	_cold_start_timer.timeout.connect(_on_cold_start_timeout)
	add_child(_cold_start_timer)

	_timeout_timer = Timer.new()
	_timeout_timer.one_shot = true
	_timeout_timer.wait_time = 30.0
	_timeout_timer.timeout.connect(_on_connection_timeout)
	add_child(_timeout_timer)

	_webrtc_ice_timer = Timer.new()
	_webrtc_ice_timer.one_shot = true
	_webrtc_ice_timer.wait_time = 7.0
	_webrtc_ice_timer.timeout.connect(_on_webrtc_ice_timeout)
	add_child(_webrtc_ice_timer)


func get_server_port() -> int:
	if OS.has_environment("PORT"):
		var env_port = OS.get_environment("PORT").to_int()
		if env_port > 0:
			return env_port
	return SERVER_PORT


func get_cloud_server_url() -> String:
	if OS.has_environment("SERVER_URL"):
		return OS.get_environment("SERVER_URL")
	if OS.has_environment("RENDER_URL"):
		return OS.get_environment("RENDER_URL")
	return DEFAULT_RENDER_URL


func get_signaling_server_url() -> String:
	if OS.has_environment("SIGNALING_URL"):
		return OS.get_environment("SIGNALING_URL")
	return DEFAULT_SIGNALING_URL


# ==============================================================================
# ROOM CODE & JOIN CODE GENERATION / RESOLUTION
# ==============================================================================

## Generates a random readable 5-character room code (e.g. "K7W9E")
func generate_room_code() -> String:
	var code := ""
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(5):
		var index := rng.randi_range(0, ROOM_CODE_ALPHABET.length() - 1)
		code += ROOM_CODE_ALPHABET[index]
	return code


## Encodes an IPv4 address into a compact 8-character hex code (e.g. 192.168.1.10 -> C0A8010A)
func encode_ip_to_code(ip_str: String) -> String:
	var parts := ip_str.strip_edges().split(".")
	if parts.size() != 4:
		return ""
	var code := ""
	for part in parts:
		var val := part.to_int()
		if val < 0 or val > 255:
			return ""
		code += "%02X" % val
	return code


## Decodes an 8-character hex code back to IPv4 (e.g. C0A8010A -> 192.168.1.10)
func decode_code_to_ip(code_str: String) -> Dictionary:
	var clean := code_str.strip_edges().to_upper()
	var result := {"valid": false, "ip": "", "error": ""}

	if clean.length() != 8:
		result["error"] = "Direct code must be 8 characters."
		return result

	var octets: Array[int] = []
	for i in range(4):
		var hex_byte := clean.substr(i * 2, 2)
		var val := ("0x" + hex_byte).hex_to_int()
		octets.append(val)

	result["valid"] = true
	result["ip"] = "%d.%d.%d.%d" % [octets[0], octets[1], octets[2], octets[3]]
	return result


## Resolves what the player entered in the Join Code / Address box.
func resolve_join_input(input_str: String) -> Dictionary:
	var clean := input_str.strip_edges()
	var result := {
		"type": "invalid",
		"target_address": "",
		"target_room_code": "",
		"direct_ip": "",
		"error": ""
	}

	if clean.is_empty():
		result["error"] = "Please enter a Join Code or Server Address."
		return result

	# Check for 8-char hex direct IP code
	if clean.length() == 8 and clean.is_valid_hex_number(false):
		var decoded := decode_code_to_ip(clean)
		if decoded["valid"]:
			result["type"] = "direct_code"
			result["target_address"] = decoded["ip"]
			result["direct_ip"] = decoded["ip"]
			return result

	# Check for 3-7 character Room Code (e.g. "XK9W" or "K7W9E")
	var room_regex = RegEx.new()
	room_regex.compile("^[a-zA-Z0-9]{3,7}$")
	if room_regex.search(clean) and not clean.contains(".") and not clean.contains(":"):
		result["type"] = "room"
		result["target_room_code"] = clean.to_upper()
		result["target_address"] = get_cloud_server_url()
		return result

	# Otherwise, treat as direct address or URL (IP, domain, ws://, wss://, enet://)
	result["type"] = "address"
	result["target_address"] = clean
	return result


# ==============================================================================
# HOSTING (WITH WEBRTC -> LOCAL FALLBACK)
# ==============================================================================

## Starts hosting.
## If client: attempts WebRTC signaling first; if signaling fails, falls back to local WebSocket/ENet host.
## If dedicated server (headless): starts headless WebSocket/ENet server directly.
func start_host(nickname: String, skin_color_str: String, force_enet: bool = false) -> Error:
	player_info["nick"] = sanitize_nickname(nickname, "Host_" + str(multiplayer.get_unique_id()))
	player_info["skin"] = skin_str_to_e(skin_color_str)

	# If headless dedicated server on Render, host directly
	if DisplayServer.get_name() == "headless":
		return _start_local_host(force_enet)

	# For client players, attempt WebRTC P2P hosting via signaling server (Tier 1)
	connection_status_changed.emit("Attempting to host via WebRTC P2P signaling...", false)
	var signaling_url := get_signaling_server_url()
	var err: Error = webrtc_client.start_host(signaling_url)

	if err != OK:
		print("[Network] WebRTC signaling unavailable, falling back to local server.")
		connection_status_changed.emit("WebRTC signaling unavailable. Fallback to Local Host...", true)
		return _start_local_host(force_enet)

	_is_webrtc_mode = true
	is_room_host = true
	_session_active = true
	return OK


func _start_local_host(force_enet: bool = false) -> Error:
	var use_ws: bool = not force_enet
	if OS.get_environment("NETWORK_PROTOCOL").to_lower() == "enet":
		use_ws = false
	if PlatformManager and not PlatformManager.can_use_raw_udp():
		use_ws = true

	var port: int = get_server_port()
	var error: Error

	if use_ws:
		var peer = WebSocketMultiplayerPeer.new()
		error = peer.create_server(port, "*")
		if error != OK:
			var err_msg := "Failed to start local WebSocket server on port %d (Error: %d)" % [port, error]
			push_error(err_msg)
			connection_failed_with_details.emit(err_msg)
			return error
		multiplayer.multiplayer_peer = peer
		print("Local WebSocket server running on port %d" % port)
	else:
		var peer = ENetMultiplayerPeer.new()
		error = peer.create_server(port, MAX_PLAYERS)
		if error != OK:
			var err_msg := "Failed to start local ENet server on port %d (Error: %d)" % [port, error]
			push_error(err_msg)
			connection_failed_with_details.emit(err_msg)
			return error
		peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
		multiplayer.multiplayer_peer = peer
		print("Local ENet server running on port %d" % port)

	_session_active = true
	is_room_host = true
	_is_webrtc_mode = false

	# Generate room code and direct IP code
	current_room_code = generate_room_code()
	server_rooms[current_room_code] = [1]
	room_code_generated.emit(current_room_code)

	var local_ip := IP.resolve_hostname(str(OS.get_environment("HOSTNAME")), IP.TYPE_IPV4)
	if local_ip.is_empty():
		local_ip = "127.0.0.1"
	current_direct_code = encode_ip_to_code(local_ip)
	if not current_direct_code.is_empty():
		direct_code_generated.emit(current_direct_code)

	connection_status_changed.emit("Hosting locally on Room Code: %s" % current_room_code, false)

	if DisplayServer.get_name() == "headless":
		return OK

	players[1] = player_info
	player_connected.emit(1, player_info)
	return OK


# ==============================================================================
# MULTI-TIER FALLBACK JOIN CASCADE
# ==============================================================================

## Joins using Join Code or Server Address.
## If Room Code is given, initiates automatic 3-Tier Fallback:
## Tier 1: WebRTC P2P -> Tier 2: Render Dedicated Cloud -> Tier 3: Direct LAN
func join_game_with_code_or_address(nickname: String, skin_color_str: String, input_str: String) -> Error:
	var resolved := resolve_join_input(input_str)
	if resolved["type"] == "invalid":
		connection_failed_with_details.emit(resolved["error"])
		return ERR_INVALID_PARAMETER

	_cascade_nickname = nickname
	_cascade_skin = skin_color_str
	_cascade_error_log.clear()

	# If direct address or IP was explicitly given, connect directly
	if resolved["type"] == "address":
		return join_game(nickname, skin_color_str, resolved["target_address"])

	# If direct IP code was given, try that direct IP first
	if resolved["type"] == "direct_code":
		_cascade_direct_ip = resolved["direct_ip"]
		return join_game(nickname, skin_color_str, _cascade_direct_ip)

	# If Room Code was given, start the 3-Tier Fallback Cascade!
	_cascade_room_code = resolved["target_room_code"]
	current_room_code = _cascade_room_code
	is_cascade_active = true

	return _execute_tier_1_webrtc()


func _execute_tier_1_webrtc() -> Error:
	current_tier = ConnectionTier.TIER_1_WEBRTC
	connection_status_changed.emit(
		"Tier 1/3: Attempting WebRTC P2P (Room: %s)..." % _cascade_room_code,
		false
	)

	var signaling_url := get_signaling_server_url()
	var err: Error = webrtc_client.start_join(signaling_url, _cascade_room_code)

	if err != OK:
		_cascade_error_log.append("Tier 1 (WebRTC): Could not start client (%d)" % err)
		return _fallback_to_tier_2()

	_is_webrtc_mode = true
	_session_active = true
	_webrtc_ice_timer.start(7.0)
	return OK


func _fallback_to_tier_2() -> Error:
	if not is_cascade_active:
		return ERR_CANT_CONNECT

	_webrtc_ice_timer.stop()
	webrtc_client.close()
	_is_webrtc_mode = false

	current_tier = ConnectionTier.TIER_2_RENDER_CLOUD
	connection_status_changed.emit(
		"WebRTC unavailable. Tier 2/3: Falling back to Render Cloud Server...",
		true
	)

	var cloud_url := get_cloud_server_url()
	var err := join_game(_cascade_nickname, _cascade_skin, cloud_url)

	if err != OK:
		_cascade_error_log.append("Tier 2 (Cloud): Failed to connect (%d)" % err)
		return _fallback_to_tier_3()

	return OK


func _fallback_to_tier_3() -> Error:
	if not is_cascade_active:
		return ERR_CANT_CONNECT

	_stop_watchdog()
	_finish_session()

	current_tier = ConnectionTier.TIER_3_DIRECT_LAN
	connection_status_changed.emit(
		"Cloud Server unreachable. Tier 3/3: Falling back to Local LAN Server...",
		true
	)

	var target_lan: String = _cascade_direct_ip if not _cascade_direct_ip.is_empty() else SERVER_ADDRESS
	var err := join_game(_cascade_nickname, _cascade_skin, target_lan)

	if err != OK:
		_cascade_error_log.append("Tier 3 (Local LAN): Failed (%d)" % err)
		_report_cascade_failure()
		return err

	return OK


func _report_cascade_failure() -> void:
	is_cascade_active = false
	_stop_watchdog()
	_finish_session()

	var summary := "All 3 connection tiers failed:\n"
	for line in _cascade_error_log:
		summary += "• " + line + "\n"
	summary += "Check your internet connection or verify the Join Code."
	connection_failed_with_details.emit(summary)


# ==============================================================================
# DIRECT CONNECTION
# ==============================================================================

func join_game(nickname: String, skin_color_str: String, address: String = SERVER_ADDRESS) -> Error:
	address = sanitize_address(address)
	if address.is_empty():
		connection_failed_with_details.emit("Invalid server address specified.")
		return ERR_INVALID_PARAMETER

	var port: int = get_server_port()
	var is_ws: bool = true
	var ws_url: String = ""
	var enet_host: String = ""
	var enet_port: int = port

	if address.begins_with("wss://") or address.begins_with("ws://"):
		is_ws = true
		ws_url = address
	elif address.begins_with("enet://"):
		if PlatformManager and not PlatformManager.can_use_raw_udp():
			var err_msg := "ENet is not supported on Web. Please use WebSocket (wss://) or WebRTC."
			connection_failed_with_details.emit(err_msg)
			return ERR_UNAVAILABLE
		is_ws = false
		var clean_enet: String = address.trim_prefix("enet://")
		if clean_enet.contains(":"):
			var parts: PackedStringArray = clean_enet.split(":")
			enet_host = parts[0]
			enet_port = parts[1].to_int()
		else:
			enet_host = clean_enet
			enet_port = port
	elif address.contains(".onrender.com") or (not address.contains(":") and address.contains(".")):
		is_ws = true
		ws_url = "wss://" + address
	else:
		is_ws = true
		if address.contains(":"):
			ws_url = "ws://" + address
		else:
			ws_url = "ws://" + address + ":" + str(port)

	_start_watchdog(ws_url if is_ws else enet_host)

	var error: Error
	if is_ws:
		var peer = WebSocketMultiplayerPeer.new()
		error = peer.create_client(ws_url)
		if error != OK:
			_stop_watchdog()
			return error
		multiplayer.multiplayer_peer = peer
	else:
		var peer = ENetMultiplayerPeer.new()
		error = peer.create_client(enet_host, enet_port)
		if error != OK:
			_stop_watchdog()
			return error
		peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
		multiplayer.multiplayer_peer = peer

	_session_active = true
	_is_webrtc_mode = false
	player_info["nick"] = sanitize_nickname(nickname, "Player_" + str(multiplayer.get_unique_id()))
	player_info["skin"] = skin_str_to_e(skin_color_str)
	return OK


# ==============================================================================
# WEBRTC EVENT HANDLERS
# ==============================================================================

func _on_webrtc_room_created(room_code: String) -> void:
	current_room_code = room_code
	room_code_generated.emit(room_code)
	connection_status_changed.emit("WebRTC P2P Room created! Code: " + room_code, false)
	players[1] = player_info
	player_connected.emit(1, player_info)


func _on_webrtc_room_joined(room_code: String) -> void:
	current_room_code = room_code
	connection_status_changed.emit("Joined WebRTC room %s! Establishing P2P mesh..." % room_code, false)


func _on_webrtc_peer_connected(peer_id: int) -> void:
	_webrtc_ice_timer.stop()
	is_cascade_active = false
	connection_status_changed.emit("Connected P2P via WebRTC to Peer %d!" % peer_id, false)
	_on_connected_ok()


func _on_webrtc_signaling_error(error_msg: String) -> void:
	print("[Network] WebRTC Error: ", error_msg)
	if is_room_host and not _session_active:
		# Fallback host to local
		connection_status_changed.emit("WebRTC signaling failed. Starting local host...", true)
		_start_local_host()
		return

	if is_cascade_active and current_tier == ConnectionTier.TIER_1_WEBRTC:
		_cascade_error_log.append("Tier 1 (WebRTC): " + error_msg)
		_fallback_to_tier_2()
	else:
		connection_failed_with_details.emit("WebRTC error: " + error_msg)


func _on_webrtc_ice_timeout() -> void:
	if is_cascade_active and current_tier == ConnectionTier.TIER_1_WEBRTC:
		_cascade_error_log.append("Tier 1 (WebRTC): P2P ICE negotiation timed out (7s)")
		_fallback_to_tier_2()


# ==============================================================================
# WATCHDOG & TIMERS
# ==============================================================================

func _start_watchdog(target: String) -> void:
	_connecting = true
	var is_render := target.contains(".onrender.com")

	if is_render:
		_timeout_timer.wait_time = 65.0
		_cold_start_timer.start(4.5)
	else:
		_timeout_timer.wait_time = 8.0
		_cold_start_timer.stop()

	_timeout_timer.start()


func _stop_watchdog() -> void:
	_connecting = false
	if _cold_start_timer:
		_cold_start_timer.stop()
	if _timeout_timer:
		_timeout_timer.stop()
	if _webrtc_ice_timer:
		_webrtc_ice_timer.stop()


func _on_cold_start_timeout() -> void:
	if _connecting:
		connection_status_changed.emit(
			"Connecting to Render cloud server... (Note: Free tier wakes up in ~50s if sleeping)",
			false
		)


func _on_connection_timeout() -> void:
	if _connecting:
		_stop_watchdog()
		if is_cascade_active:
			if current_tier == ConnectionTier.TIER_2_RENDER_CLOUD:
				_cascade_error_log.append("Tier 2 (Cloud): Render server timed out")
				_fallback_to_tier_3()
				return
			elif current_tier == ConnectionTier.TIER_3_DIRECT_LAN:
				_cascade_error_log.append("Tier 3 (Local LAN): Timed out")
				_report_cascade_failure()
				return

		_finish_session()
		connection_failed_with_details.emit(
			"Connection timed out. Server might be offline or unreachable."
		)


# ==============================================================================
# MULTIPLAYER EVENT HANDLERS & ROOM ROUTING
# ==============================================================================

func _on_connected_ok() -> void:
	_stop_watchdog()
	is_cascade_active = false
	connection_status_changed.emit("Connected successfully! Syncing player state...", false)

	var peer_id = multiplayer.get_unique_id()
	players[peer_id] = player_info
	player_connected.emit(peer_id, player_info)

	if not current_room_code.is_empty():
		_request_join_room.rpc_id(1, current_room_code, player_info)
	else:
		_register_player.rpc_id(1, player_info)


func _on_player_connected(id: int) -> void:
	if not multiplayer.is_server() and not _is_webrtc_mode:
		return
	for peer_id in players:
		_sync_registered_player.rpc_id(id, peer_id, players[peer_id])


@rpc("any_peer", "reliable")
func _request_join_room(room_code: String, new_player_info: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var new_player_id = multiplayer.get_remote_sender_id()
	if new_player_id == 0 or players.has(new_player_id):
		return

	var clean_code = room_code.strip_edges().to_upper()
	if not server_rooms.has(clean_code):
		server_rooms[clean_code] = []

	server_rooms[clean_code].append(new_player_id)
	_register_player(new_player_info)


@rpc("any_peer", "reliable")
func _register_player(new_player_info):
	if not multiplayer.is_server() and not _is_webrtc_mode:
		return
	if not (new_player_info is Dictionary):
		return
	var new_player_id = multiplayer.get_remote_sender_id()
	if new_player_id == 0:
		return
	if players.has(new_player_id):
		return
	var sanitized_info = sanitize_player_info(new_player_info, "Player_" + str(new_player_id))
	players[new_player_id] = sanitized_info
	player_connected.emit(new_player_id, sanitized_info)
	_sync_registered_player.rpc(new_player_id, sanitized_info)


func _on_player_disconnected(id: int) -> void:
	players.erase(id)
	for code in server_rooms:
		server_rooms[code].erase(id)


func _on_connection_failed() -> void:
	_stop_watchdog()
	if is_cascade_active:
		if current_tier == ConnectionTier.TIER_2_RENDER_CLOUD:
			_cascade_error_log.append("Tier 2 (Cloud): Server refused connection or is asleep")
			_fallback_to_tier_3()
			return
		elif current_tier == ConnectionTier.TIER_3_DIRECT_LAN:
			_cascade_error_log.append("Tier 3 (Local LAN): Connection failed")
			_report_cascade_failure()
			return

	_finish_session()
	connection_failed_with_details.emit("Connection failed. Server refused connection or is unreachable.")


func _on_server_disconnected() -> void:
	_stop_watchdog()
	_finish_session()
	connection_failed_with_details.emit("Disconnected from server.")


func leave_game() -> void:
	_stop_watchdog()
	is_cascade_active = false
	if webrtc_client:
		webrtc_client.close()
	var peer := multiplayer.multiplayer_peer
	if peer:
		peer.close()
	_finish_session()


func _finish_session() -> void:
	_stop_watchdog()
	is_cascade_active = false
	var had_session := _session_active or multiplayer.multiplayer_peer != null or not players.is_empty()
	_session_active = false
	_is_webrtc_mode = false
	multiplayer.multiplayer_peer = null
	players.clear()
	current_room_code = ""
	current_direct_code = ""
	is_room_host = false
	if had_session:
		server_disconnected.emit()


# ==============================================================================
# SANITIZATION HELPERS
# ==============================================================================

func skin_str_to_e(s) -> Character.SkinColor:
	match str(s).strip_edges().to_lower():
		"blue":
			return Character.SkinColor.BLUE
		"yellow":
			return Character.SkinColor.YELLOW
		"green":
			return Character.SkinColor.GREEN
		"red":
			return Character.SkinColor.RED
		_:
			return Character.SkinColor.BLUE


@rpc("authority", "reliable")
func _sync_registered_player(peer_id: int, registered_player_info: Dictionary) -> void:
	if multiplayer.is_server():
		return
	if players.has(peer_id):
		return
	var sanitized_info = sanitize_player_info(registered_player_info, "Player_" + str(peer_id))
	players[peer_id] = sanitized_info
	player_connected.emit(peer_id, sanitized_info)


func sanitize_player_info(info: Dictionary, fallback_nick: String) -> Dictionary:
	return {
		"nick": sanitize_nickname(str(info.get("nick", "")), fallback_nick),
		"skin": sanitize_skin_value(info.get("skin", Character.SkinColor.BLUE))
	}


func sanitize_nickname(nickname: String, fallback: String) -> String:
	var clean := ""
	var last_was_space := false
	for i in range(nickname.length()):
		var codepoint := nickname.unicode_at(i)
		if codepoint <= 31 or codepoint == 127:
			if not last_was_space:
				clean += " "
				last_was_space = true
			continue

		var character := nickname.substr(i, 1)
		if character == " ":
			if last_was_space:
				continue
			last_was_space = true
		else:
			last_was_space = false
		clean += character

	clean = clean.strip_edges()
	if clean.is_empty():
		clean = fallback.strip_edges()
	if clean.length() > MAX_NICK_LENGTH:
		clean = clean.substr(0, MAX_NICK_LENGTH).strip_edges()
	if clean.is_empty():
		clean = "Player"
	return clean


func sanitize_address(address: String) -> String:
	var clean = address.strip_edges()
	if clean.is_empty():
		return SERVER_ADDRESS
	if clean.length() > MAX_ADDRESS_LENGTH:
		return ""
	clean = clean.trim_suffix("/")
	var regex = RegEx.new()
	regex.compile("^[a-zA-Z0-9_\\-\\.:/]+$")
	if not regex.search(clean):
		return ""
	return clean


func sanitize_skin_value(value) -> Character.SkinColor:
	if value is int:
		match value:
			Character.SkinColor.BLUE, Character.SkinColor.YELLOW, Character.SkinColor.GREEN, Character.SkinColor.RED:
				return value
			_:
				return Character.SkinColor.BLUE
	return skin_str_to_e(str(value))
