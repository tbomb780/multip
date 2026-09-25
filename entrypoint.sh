#!/usr/bin/env bash
set -e

# Render provides $PORT dynamically (default to 10000 if unset)
export PORT="${PORT:-10000}"

echo "=================================================="
echo " Starting Godot 4 Dedicated Multiplayer Server   "
echo " Protocol: WebSocketMultiplayerPeer (TCP/WSS)     "
echo " Listening on Port: ${PORT}                      "
echo "=================================================="

exec godot --headless --path /app
