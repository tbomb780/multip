class_name WebRTCSignalingClient
extends Node

## WebRTC Peer-to-Peer Signaling Client (Approach C)
## Connects to a lightweight WebSocket signaling server on Render.com or locally.
## Generates/joins room codes and exchanges SDP offers/answers and ICE candidates.
## Equipped with connection timeout handling and automatic action sequencing.

signal room_created(room_code: String)
signal room_joined(room_code: String)
signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal signaling_error(message: String)

const DEFAULT_STUN_SERVERS := [
	{"urls": ["stun:stun.l.google.com:19302"]},
	{"urls": ["stun:stun1.l.google.com:19302"]}
]

const CONNECTION_TIMEOUT := 5.0

var rtc_peer: WebRTCMultiplayerPeer = WebRTCMultiplayerPeer.new()
var _ws_client: WebSocketPeer = WebSocketPeer.new()
var _signaling_url: String = ""
var _is_connected_to_signaling: bool = false
var _is_connecting: bool = false
var _connection_timer: float = 0.0
var _room_code: String = ""
var _is_host: bool = false
var _pending_action: String = "" # "create" or "join"

# Peer connections mapped by peer_id
var _peers: Dictionary = {} # peer_id -> WebRTCPeerConnection


func _process(delta: float) -> void:
	if not _is_connecting and not _is_connected_to_signaling:
		return

	_ws_client.poll()
	var state := _ws_client.get_ready_state()

	if state == WebSocketPeer.STATE_CONNECTING:
		_connection_timer += delta
		if _connection_timer >= CONNECTION_TIMEOUT:
			_is_connecting = false
			_ws_client.close()
			signaling_error.emit("Signaling server connection timed out (%ds)." % int(CONNECTION_TIMEOUT))
			return

	elif state == WebSocketPeer.STATE_OPEN:
		if not _is_connected_to_signaling:
			_is_connecting = false
			_is_connected_to_signaling = true
			_connection_timer = 0.0
			_on_signaling_connected()

		while _ws_client.get_available_packet_count() > 0:
			var packet := _ws_client.get_packet()
			var msg_str := packet.get_string_from_utf8()
			_handle_signaling_message(msg_str)

	elif state == WebSocketPeer.STATE_CLOSED:
		if _is_connecting or _is_connected_to_signaling:
			_is_connecting = false
			_is_connected_to_signaling = false
			_connection_timer = 0.0
			signaling_error.emit("Signaling server connection closed or unreachable.")


func start_host(url: String) -> Error:
	_is_host = true
	_pending_action = "create"
	return connect_to_signaling(url)


func start_join(url: String, room_code: String) -> Error:
	_is_host = false
	_room_code = room_code.strip_edges().to_upper()
	_pending_action = "join"
	return connect_to_signaling(url)


func connect_to_signaling(url: String) -> Error:
	close()
	_signaling_url = url
	_is_connecting = true
	_connection_timer = 0.0
	var err := _ws_client.connect_to_url(url)
	if err != OK:
		_is_connecting = false
		signaling_error.emit("Failed to initiate connection to signaling server: " + str(err))
	return err


func _on_signaling_connected() -> void:
	print("[WebRTC] Connected to signaling server at %s" % _signaling_url)
	if _pending_action == "create":
		_send_json({"type": "create_room"})
	elif _pending_action == "join":
		_send_json({"type": "join_room", "room_code": _room_code})
	_pending_action = ""


func _handle_signaling_message(msg_str: String) -> void:
	var json = JSON.new()
	if json.parse(msg_str) != OK:
		return
	var data = json.get_data()
	if not (data is Dictionary):
		return

	var msg_type = data.get("type", "")
	match msg_type:
		"room_created":
			_room_code = data.get("room_code", "")
			rtc_peer.create_mesh(1)
			multiplayer.multiplayer_peer = rtc_peer
			room_created.emit(_room_code)

		"room_joined":
			_room_code = data.get("room_code", "")
			var my_peer_id: int = data.get("peer_id", 2)
			rtc_peer.create_mesh(my_peer_id)
			multiplayer.multiplayer_peer = rtc_peer
			room_joined.emit(_room_code)

		"peer_joined":
			var remote_peer_id: int = data.get("peer_id", 0)
			if remote_peer_id > 0:
				_initiate_peer_connection(remote_peer_id, true)

		"offer":
			var from_id: int = data.get("from", 0)
			var sdp: String = data.get("sdp", "")
			_handle_offer(from_id, sdp)

		"answer":
			var from_id: int = data.get("from", 0)
			var sdp: String = data.get("sdp", "")
			_handle_answer(from_id, sdp)

		"candidate":
			var from_id: int = data.get("from", 0)
			var mid: String = data.get("mid", "")
			var index: int = data.get("index", 0)
			var sdp_name: String = data.get("sdp", "")
			_handle_candidate(from_id, mid, index, sdp_name)

		"peer_disconnected":
			var peer_id: int = data.get("peer_id", 0)
			if _peers.has(peer_id):
				_peers.erase(peer_id)
			peer_disconnected.emit(peer_id)

		"error":
			signaling_error.emit(str(data.get("message", "Signaling error")))


func _initiate_peer_connection(remote_id: int, is_offer: bool) -> WebRTCPeerConnection:
	var pc := WebRTCPeerConnection.new()
	pc.initialize({"iceServers": DEFAULT_STUN_SERVERS})

	pc.session_description_created.connect(func(type, sdp):
		pc.set_local_description(type, sdp)
		_send_json({"type": type, "to": remote_id, "sdp": sdp})
	)

	pc.ice_candidate_created.connect(func(mid, index, sdp):
		_send_json({"type": "candidate", "to": remote_id, "mid": mid, "index": index, "sdp": sdp})
	)

	rtc_peer.add_peer(pc, remote_id)
	_peers[remote_id] = pc

	if is_offer:
		pc.create_offer()

	return pc


func _handle_offer(from_id: int, sdp: String) -> void:
	var pc = _initiate_peer_connection(from_id, false)
	pc.set_remote_description("offer", sdp)


func _handle_answer(from_id: int, sdp: String) -> void:
	if _peers.has(from_id):
		var pc: WebRTCPeerConnection = _peers[from_id]
		pc.set_remote_description("answer", sdp)


func _handle_candidate(from_id: int, mid: String, index: int, sdp: String) -> void:
	if _peers.has(from_id):
		var pc: WebRTCPeerConnection = _peers[from_id]
		pc.add_ice_candidate(mid, index, sdp)


func _send_json(dict: Dictionary) -> void:
	if _ws_client.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var json_str := JSON.stringify(dict)
		_ws_client.send_text(json_str)


func close() -> void:
	_is_connecting = false
	_is_connected_to_signaling = false
	_connection_timer = 0.0
	_pending_action = ""
	if _ws_client.get_ready_state() == WebSocketPeer.STATE_OPEN or _ws_client.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		_ws_client.close()
	_peers.clear()
	if rtc_peer:
		rtc_peer.close()
