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
signal room_joined(room_code: String)
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
const DEFAULT_RENDER_URL: String = "wss://multip.onrender.com"
const DEFAULT_SIGNALING_URL: String = "wss://godot-webrtc-signaling.onrender.com"

var last_server_address: String = ""
var players: Dictionary = {}
var player_info: Dictionary = {"nick": "host", "skin": Character.SkinColor.BLUE}
var _session_active := false

# Room management
var current_room_code: String = ""
var current_direct_code: String = ""
var is_room_host: bool = false
var server_rooms: Dictionary = {} # room_code -> Dictionary {"host": int, "peers": Array}
var peer_to_room: Dictionary = {} # peer_id -> room_code

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
	if OS.has_feature("web"):
		var web_host = JavaScriptBridge.eval("window.location.host")
		if web_host and str(web_host) != "" and str(web_host) != "null":
			var host_str = str(web_host).strip_edges()
			if host_str.contains(".onrender.com"):
				return "wss://" + host_str
			elif host_str.begins_with("localhost") or host_str.begins_with("127.0.0.1"):
				return "ws://" + host_str
			elif not host_str.is_empty():
				var is_https = JavaScriptBridge.eval("window.location.protocol === 'https:'")
				var proto = "wss://" if is_https else "ws://"
				return proto + host_str
	if not last_server_address.is_empty():
		return last_server_address
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

	# Check for URL or address containing room query, e.g. "https://multip.onrender.com/?room=KW6B9"
	if clean.contains("room="):
		var code_part = clean.split("room=")[1]
		if code_part.contains("&"):
			code_part = code_part.split("&")[0]
		code_part = code_part.strip_edges().to_upper()
		if not code_part.is_empty():
			result["type"] = "room"
			result["target_room_code"] = code_part
			var base_addr = clean.split("?")[0].strip_edges()
			if base_addr.begins_with("https://"):
				result["target_address"] = "wss://" + base_addr.trim_prefix("https://")
			elif base_addr.begins_with("http://"):
				result["target_address"] = "ws://" + base_addr.trim_prefix("http://")
			elif not base_addr.is_empty() and (base_addr.contains(".") or base_addr.contains(":")):
				result["target_address"] = base_addr
			else:
				result["target_address"] = get_cloud_server_url()
			return result

	# Check for 8-char hex direct IP code
	if clean.length() == 8 and clean.is_valid_hex_number(false):
		var decoded := decode_code_to_ip(clean)
		if decoded["valid"]:
			result["type"] = "direct_code"
			result["target_address"] = decoded["ip"]
			result["direct_ip"] = decoded["ip"]
			return result

	# Check for 3-7 character Room Code (e.g. "XK9W" or "KW6B9")
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
# HOSTING (SERVER ROOM HOSTING & LOCAL FALLBACK)
# ==============================================================================

## Starts hosting.
## If dedicated server (headless): starts headless WebSocket/ENet server on port.
## If web client or connecting to remote server: creates a hosted room session on the server.
## If local desktop: starts a local server on port 8080 (or connects as room host if port is in use).
func start_host(nickname: String, skin_color_str: String, address: String = "", force_enet: bool = false) -> Error:
	player_info["nick"] = sanitize_nickname(nickname, "Host_" + str(multiplayer.get_unique_id()))
	player_info["skin"] = skin_str_to_e(skin_color_str)

	var target_address = address.strip_edges()
	if target_address.is_empty():
		# If headless dedicated server on Render/Linux without target address, host directly
		if DisplayServer.get_name() == "headless":
			return _start_local_host(force_enet)
		if PlatformManager and PlatformManager.is_web:
			target_address = get_cloud_server_url()
		else:
			target_address = get_cloud_server_url()

	# If target_address looks like a 3-7 char room code, use the cloud server URL
	var room_regex = RegEx.new()
	room_regex.compile("^[a-zA-Z0-9]{3,7}$")
	if room_regex.search(target_address) and not target_address.contains(".") and not target_address.contains(":"):
		target_address = get_cloud_server_url()

	var is_server_target = (
		(PlatformManager and PlatformManager.is_web) or
		target_address.begins_with("wss://") or
		target_address.begins_with("ws://") or
		target_address.contains(".onrender.com")
	)

	if is_server_target:
		return _host_room_on_server(target_address, skin_color_str)

	# On desktop without cloud address, try local server creation
	var err = _start_local_host(force_enet)
	if err != OK:
		# If local server failed (e.g. port already bound by background headless server daemon):
		print("[Network] Local port busy, connecting as room host to local server on port %d..." % get_server_port())
		return _host_room_on_server("ws://127.0.0.1:%d" % get_server_port(), skin_color_str)
	return OK


func _host_room_on_server(server_address: String, skin_val = "Blue") -> Error:
	if server_address.is_empty():
		server_address = get_cloud_server_url()

	current_room_code = generate_room_code()
	is_room_host = true
	_is_webrtc_mode = false

	connection_status_changed.emit("Connecting to server to host Room %s..." % current_room_code, false)

	var err = join_game(player_info["nick"], skin_val, server_address)
	if err != OK:
		connection_status_changed.emit("Failed to connect to server: %d" % err, true)
		return err
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
	_is_webrtc_mode = false

	if DisplayServer.get_name() == "headless":
		current_room_code = ""
		print("[Server] Dedicated server ready on port %d. Waiting for rooms and players..." % port)
		return OK

	is_room_host = true
	current_room_code = generate_room_code()
	server_rooms[current_room_code] = {"host": 1, "peers": [1]}
	peer_to_room[1] = current_room_code
	room_code_generated.emit(current_room_code)

	var local_ip := IP.resolve_hostname(str(OS.get_environment("HOSTNAME")), IP.TYPE_IPV4)
	if local_ip.is_empty():
		local_ip = "127.0.0.1"
	current_direct_code = encode_ip_to_code(local_ip)
	if not current_direct_code.is_empty():
		direct_code_generated.emit(current_direct_code)

	connection_status_changed.emit("Hosting locally on Room Code: %s" % current_room_code, false)

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

	# If Room Code was given, connect to Cloud Server room first!
	_cascade_room_code = resolved["target_room_code"]
	current_room_code = _cascade_room_code
	is_room_host = false
	is_cascade_active = true

	return _execute_tier_2_cloud()


func _execute_tier_2_cloud() -> Error:
	current_tier = ConnectionTier.TIER_2_RENDER_CLOUD
	connection_status_changed.emit(
		"Connecting to server for Room '%s'..." % _cascade_room_code,
		false
	)

	var cloud_url := get_cloud_server_url()
	var err := join_game(_cascade_nickname, _cascade_skin, cloud_url)

	if err != OK:
		_cascade_error_log.append("Cloud server connection failed (%d)" % err)
		return _fallback_to_tier_1_webrtc()

	return OK


func _fallback_to_tier_1_webrtc() -> Error:
	if not is_cascade_active:
		return ERR_CANT_CONNECT

	_webrtc_ice_timer.stop()
	webrtc_client.close()

	current_tier = ConnectionTier.TIER_1_WEBRTC
	connection_status_changed.emit(
		"Cloud unavailable. Attempting WebRTC P2P fallback (Room: %s)..." % _cascade_room_code,
		true
	)

	var signaling_url := get_signaling_server_url()
	var err: Error = webrtc_client.start_join(signaling_url, _cascade_room_code)

	if err != OK:
		_cascade_error_log.append("WebRTC fallback failed (%d)" % err)
		return _fallback_to_tier_3()

	_is_webrtc_mode = true
	_session_active = true
	_webrtc_ice_timer.start(7.0)
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

func join_game(nickname: String, skin_color_val, address: String = SERVER_ADDRESS) -> Error:
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

	last_server_address = ws_url if is_ws else enet_host
	_start_watchdog(last_server_address)

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
	player_info["skin"] = sanitize_skin_value(skin_color_val)
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
		_fallback_to_tier_3()
	else:
		connection_failed_with_details.emit("WebRTC error: " + error_msg)


func _on_webrtc_ice_timeout() -> void:
	if is_cascade_active and current_tier == ConnectionTier.TIER_1_WEBRTC:
		_cascade_error_log.append("Tier 1 (WebRTC): P2P ICE negotiation timed out (7s)")
		_fallback_to_tier_3()


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
				_fallback_to_tier_1_webrtc()
				return
			elif current_tier == ConnectionTier.TIER_1_WEBRTC:
				_cascade_error_log.append("Tier 1 (WebRTC): Timed out")
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

	var peer_id = multiplayer.get_unique_id()

	if is_room_host:
		connection_status_changed.emit("Connected! Registering Room '%s'..." % current_room_code, false)
		_request_create_room.rpc_id(1, current_room_code, player_info)
	elif not current_room_code.is_empty():
		connection_status_changed.emit("Connected! Joining Room '%s'..." % current_room_code, false)
		_request_join_room.rpc_id(1, current_room_code, player_info)
	else:
		connection_status_changed.emit("Connected successfully! Syncing player state...", false)
		players[peer_id] = player_info
		player_connected.emit(peer_id, player_info)
		_register_player.rpc_id(1, player_info)


func _on_player_connected(_id: int) -> void:
	# Handshake and state sync occur when peer sends registration RPC
	pass


@rpc("any_peer", "reliable")
func _request_create_room(room_code: String, host_info: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var host_id = multiplayer.get_remote_sender_id()
	if host_id == 0:
		return

	var clean_code = room_code.strip_edges().to_upper()
	if clean_code.is_empty():
		clean_code = generate_room_code()

	while server_rooms.has(clean_code):
		clean_code = generate_room_code()

	server_rooms[clean_code] = {
		"host": host_id,
		"peers": [host_id]
	}
	peer_to_room[host_id] = clean_code

	var sanitized_info = sanitize_player_info(host_info, "Host_" + str(host_id))
	players[host_id] = sanitized_info

	print("[Server] Created Room '%s' for Host ID %d (%s)" % [clean_code, host_id, sanitized_info.get("nick")])

	_room_created_confirmed.rpc_id(host_id, clean_code)


@rpc("authority", "reliable")
func _room_created_confirmed(room_code: String) -> void:
	current_room_code = room_code
	is_room_host = true
	_session_active = true

	var my_id = multiplayer.get_unique_id()
	players[my_id] = player_info
	player_connected.emit(my_id, player_info)
	room_code_generated.emit(room_code)
	connection_status_changed.emit("Room '%s' hosted! Share this code with friends." % room_code, false)


@rpc("any_peer", "reliable")
func _request_join_room(room_code: String, new_player_info: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var joiner_id = multiplayer.get_remote_sender_id()
	if joiner_id == 0:
		return

	var clean_code = room_code.strip_edges().to_upper()
	if not server_rooms.has(clean_code):
		_room_join_rejected.rpc_id(joiner_id, "Room code '%s' not found. Check the code or host a new room." % clean_code)
		return

	var room_data: Dictionary = server_rooms[clean_code]
	var room_peers: Array = room_data.get("peers", [])

	if room_peers.size() >= MAX_PLAYERS:
		_room_join_rejected.rpc_id(joiner_id, "Room '%s' is full (max %d players)." % [clean_code, MAX_PLAYERS])
		return

	room_peers.append(joiner_id)
	peer_to_room[joiner_id] = clean_code

	var sanitized_info = sanitize_player_info(new_player_info, "Player_" + str(joiner_id))
	players[joiner_id] = sanitized_info

	print("[Server] Peer %d (%s) joined Room '%s'" % [joiner_id, sanitized_info.get("nick"), clean_code])

	# Confirm to joiner
	_room_joined_confirmed.rpc_id(joiner_id, clean_code)

	# Sync existing peers in this room to the new joiner
	for other_id in room_peers:
		if other_id != joiner_id and players.has(other_id):
			_sync_registered_player.rpc_id(joiner_id, other_id, players[other_id])

	# Sync the new joiner to all other peers in this room
	for other_id in room_peers:
		if other_id != joiner_id:
			_sync_registered_player.rpc_id(other_id, joiner_id, sanitized_info)


@rpc("authority", "reliable")
func _room_joined_confirmed(room_code: String) -> void:
	current_room_code = room_code
	is_room_host = false
	_session_active = true

	var my_id = multiplayer.get_unique_id()
	players[my_id] = player_info
	player_connected.emit(my_id, player_info)
	room_joined.emit(room_code)
	connection_status_changed.emit("Joined Room '%s'!" % room_code, false)


@rpc("authority", "reliable")
func _room_join_rejected(error_message: String) -> void:
	_stop_watchdog()
	_finish_session()
	connection_failed_with_details.emit(error_message)


@rpc("any_peer", "reliable")
func _register_player(new_player_info):
	if not multiplayer.is_server() and not _is_webrtc_mode:
		return
	if not (new_player_info is Dictionary):
		return
	var new_player_id = multiplayer.get_remote_sender_id()
	if new_player_id == 0 or players.has(new_player_id):
		return

	peer_to_room[new_player_id] = ""
	var sanitized_info = sanitize_player_info(new_player_info, "Player_" + str(new_player_id))
	players[new_player_id] = sanitized_info
	player_connected.emit(new_player_id, sanitized_info)

	for other_id in players:
		if other_id != new_player_id and peer_to_room.get(other_id, "") == "":
			_sync_registered_player.rpc_id(new_player_id, other_id, players[other_id])
			_sync_registered_player.rpc_id(other_id, new_player_id, sanitized_info)


func get_room_peers(peer_id: int) -> Array:
	var code = peer_to_room.get(peer_id, "")
	if not code.is_empty() and server_rooms.has(code):
		return server_rooms[code].get("peers", []).duplicate()
	var default_peers: Array = []
	for p in players:
		if peer_to_room.get(p, "") == "":
			default_peers.append(p)
	return default_peers


func _on_player_disconnected(id: int) -> void:
	var room_code: String = peer_to_room.get(id, "")
	peer_to_room.erase(id)
	players.erase(id)

	if not room_code.is_empty() and server_rooms.has(room_code):
		var room_peers: Array = server_rooms[room_code].get("peers", [])
		room_peers.erase(id)
		if room_peers.is_empty():
			server_rooms.erase(room_code)
			print("[Server] Room '%s' closed (all players left)" % room_code)
		elif server_rooms[room_code].get("host") == id:
			server_rooms[room_code]["host"] = room_peers[0]
			print("[Server] Room '%s' host migrated to %d" % [room_code, room_peers[0]])


func _on_connection_failed() -> void:
	_stop_watchdog()
	if is_cascade_active:
		if current_tier == ConnectionTier.TIER_2_RENDER_CLOUD:
			_cascade_error_log.append("Tier 2 (Cloud): Server refused connection or is asleep")
			_fallback_to_tier_1_webrtc()
			return
		elif current_tier == ConnectionTier.TIER_1_WEBRTC:
			_cascade_error_log.append("Tier 1 (WebRTC): Connection failed")
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
	peer_to_room.clear()
	if DisplayServer.get_name() != "headless":
		server_rooms.clear()
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
