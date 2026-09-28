/**
 * Lightweight WebRTC Signaling Server for Godot 4 (Approach C)
 * Runs on Node.js / Render.com Free Tier
 * Handles Room Codes and exchanges SDP / ICE candidates for P2P multiplayer.
 */

const { WebSocketServer } = require("ws");
const http = require("http");

const PORT = process.env.PORT || 10000;
const server = http.createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("Godot WebRTC Signaling Server Active.\n");
});

const wss = new WebSocketServer({ server });

// Rooms map: roomCode -> { hostWs, peers: Map(peerId -> ws) }
const rooms = new Map();
let nextPeerId = 2; // Host is usually 1, clients 2, 3, ...

function generateRoomCode() {
    const chars = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
    let code = "";
    for (let i = 0; i < 5; i++) {
        code += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return code;
}

wss.on("connection", (ws) => {
    ws.peerId = null;
    ws.roomCode = null;

    ws.on("message", (message) => {
        try {
            const data = JSON.parse(message);
            handleMessage(ws, data);
        } catch (err) {
            console.error("Invalid JSON message:", err);
        }
    });

    ws.on("close", () => {
        if (ws.roomCode && rooms.has(ws.roomCode)) {
            const room = rooms.get(ws.roomCode);
            if (room.hostWs === ws) {
                // Host left, notify all peers and delete room
                for (const peerWs of room.peers.values()) {
                    if (peerWs.readyState === 1) {
                        peerWs.send(JSON.stringify({ type: "error", message: "Host closed the room." }));
                    }
                }
                rooms.delete(ws.roomCode);
                console.log(`Room ${ws.roomCode} closed (host disconnected).`);
            } else {
                room.peers.delete(ws.peerId);
                if (room.hostWs.readyState === 1) {
                    room.hostWs.send(JSON.stringify({ type: "peer_disconnected", peer_id: ws.peerId }));
                }
                console.log(`Peer ${ws.peerId} disconnected from room ${ws.roomCode}.`);
            }
        }
    });
});

function handleMessage(ws, data) {
    switch (data.type) {
        case "create_room": {
            let roomCode = generateRoomCode();
            while (rooms.has(roomCode)) {
                roomCode = generateRoomCode();
            }

            ws.peerId = 1; // Host is 1
            ws.roomCode = roomCode;
            rooms.set(roomCode, { hostWs: ws, peers: new Map() });

            ws.send(JSON.stringify({ type: "room_created", room_code: roomCode, peer_id: 1 }));
            console.log(`Created room ${roomCode} for host (Peer 1)`);
            break;
        }

        case "join_room": {
            const code = String(data.room_code || "").trim().toUpperCase();
            if (!rooms.has(code)) {
                ws.send(JSON.stringify({ type: "error", message: `Room ${code} not found.` }));
                return;
            }

            const room = rooms.get(code);
            const peerId = nextPeerId++;
            ws.peerId = peerId;
            ws.roomCode = code;

            room.peers.set(peerId, ws);

            // Notify joiner
            ws.send(JSON.stringify({ type: "room_joined", room_code: code, peer_id: peerId }));

            // Notify host to create offer to this peer
            if (room.hostWs.readyState === 1) {
                room.hostWs.send(JSON.stringify({ type: "peer_joined", peer_id: peerId }));
            }
            console.log(`Peer ${peerId} joined room ${code}`);
            break;
        }

        case "offer":
        case "answer":
        case "candidate": {
            const toId = data.to;
            const room = rooms.get(ws.roomCode);
            if (!room) return;

            data.from = ws.peerId;

            if (toId === 1 && room.hostWs.readyState === 1) {
                room.hostWs.send(JSON.stringify(data));
            } else if (room.peers.has(toId)) {
                const targetWs = room.peers.get(toId);
                if (targetWs && targetWs.readyState === 1) {
                    targetWs.send(JSON.stringify(data));
                }
            }
            break;
        }
    }
}

server.listen(PORT, () => {
    console.log(`WebRTC Signaling Server listening on port ${PORT}`);
});
