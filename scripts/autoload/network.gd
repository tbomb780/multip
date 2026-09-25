extends Node

signal player_connected(peer_id, player_info)
signal server_disconnected

const SERVER_ADDRESS: String = "127.0.0.1"
const SERVER_PORT: int = 8080
const MAX_PLAYERS: int = 10
const MAX_NICK_LENGTH := 24
const MAX_ADDRESS_LENGTH := 253

var players = {}
var player_info = {"nick": "host", "skin": Character.SkinColor.BLUE}
var _session_active := false


func _ready() -> void:
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.peer_disconnected.connect(_on_player_disconnected)
	multiplayer.peer_connected.connect(_on_player_connected)
	multiplayer.connected_to_server.connect(_on_connected_ok)


func get_server_port() -> int:
	if OS.has_environment("PORT"):
		var env_port = OS.get_environment("PORT").to_int()
		if env_port > 0:
			return env_port
	return SERVER_PORT


func start_host(nickname: String, skin_color_str: String, force_enet: bool = false):
	# On Render and cloud platforms, raw UDP is not supported.
	# We default to WebSocketMultiplayerPeer (TCP) which works through Render's reverse proxy,
	# local testing, and Web/HTML5 exports.
	var use_ws: bool = not force_enet
	if OS.get_environment("NETWORK_PROTOCOL").to_lower() == "enet":
		use_ws = false

	var port: int = get_server_port()
	var error: Error

	if use_ws:
		var peer = WebSocketMultiplayerPeer.new()
		error = peer.create_server(port, "*")
		if error != OK:
			push_error("Failed to start WebSocket server on port %d. Error: %d" % [port, error])
			return error
		multiplayer.multiplayer_peer = peer
		print("WebSocket server running on port %d (bound to *)" % port)
	else:
		var peer = ENetMultiplayerPeer.new()
		error = peer.create_server(port, MAX_PLAYERS)
		if error != OK:
			push_error("Failed to start ENet server on port %d. Error: %d" % [port, error])
			return error
		peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
		multiplayer.multiplayer_peer = peer
		print("ENet server running on port %d" % port)

	_session_active = true

	player_info["nick"] = sanitize_nickname(nickname, "Host_" + str(multiplayer.get_unique_id()))
	player_info["skin"] = skin_str_to_e(skin_color_str)

	if DisplayServer.get_name() == "headless":
		return OK

	players[1] = player_info
	player_connected.emit(1, player_info)
	return OK


func join_game(nickname: String, skin_color_str: String, address: String = SERVER_ADDRESS):
	address = sanitize_address(address)
	if address.is_empty():
		return ERR_INVALID_PARAMETER

	var port: int = get_server_port()
	var is_ws: bool = true
	var ws_url: String = ""
	var enet_host: String = ""
	var enet_port: int = port

	# Protocol auto-detection:
	if address.begins_with("wss://") or address.begins_with("ws://"):
		is_ws = true
		ws_url = address
	elif address.begins_with("enet://"):
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
		# Render domain or cloud domain without protocol prefix: default to secure WebSocket (wss)
		is_ws = true
		ws_url = "wss://" + address
	else:
		# Local IP or hostname: default to ws://
		is_ws = true
		if address.contains(":"):
			ws_url = "ws://" + address
		else:
			ws_url = "ws://" + address + ":" + str(port)

	var error: Error
	if is_ws:
		print("Connecting via WebSocket to %s" % ws_url)
		var peer = WebSocketMultiplayerPeer.new()
		error = peer.create_client(ws_url)
		if error != OK:
			push_error("Failed to connect via WebSocket to %s. Error: %d" % [ws_url, error])
			return error
		multiplayer.multiplayer_peer = peer
	else:
		print("Connecting via ENet to %s:%d" % [enet_host, enet_port])
		var peer = ENetMultiplayerPeer.new()
		error = peer.create_client(enet_host, enet_port)
		if error != OK:
			push_error("Failed to connect via ENet to %s:%d. Error: %d" % [enet_host, enet_port, error])
			return error
		peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
		multiplayer.multiplayer_peer = peer

	_session_active = true

	player_info["nick"] = sanitize_nickname(nickname, "Player_" + str(multiplayer.get_unique_id()))
	player_info["skin"] = skin_str_to_e(skin_color_str)
	return OK


func _on_connected_ok():
	var peer_id = multiplayer.get_unique_id()
	players[peer_id] = player_info
	player_connected.emit(peer_id, player_info)
	_register_player.rpc_id(1, player_info)


func _on_player_connected(id):
	if not multiplayer.is_server():
		return
	for peer_id in players:
		_sync_registered_player.rpc_id(id, peer_id, players[peer_id])


@rpc("any_peer", "reliable")
func _register_player(new_player_info):
	if not multiplayer.is_server():
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


func _on_player_disconnected(id):
	players.erase(id)


func _on_connection_failed():
	_finish_session()


func _on_server_disconnected():
	_finish_session()


func leave_game() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer:
		peer.close()
	_finish_session()


func _finish_session() -> void:
	var had_session := _session_active or multiplayer.multiplayer_peer != null or not players.is_empty()
	_session_active = false
	multiplayer.multiplayer_peer = null
	players.clear()
	if had_session:
		server_disconnected.emit()


func skin_str_to_e(s):
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
func _sync_registered_player(peer_id: int, registered_player_info: Dictionary):
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
