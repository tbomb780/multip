#!/usr/bin/env bash
set -e

# Render provides $PORT dynamically (default to 10000 if unset)
PUBLIC_PORT="${PORT:-10000}"
INTERNAL_PORT="8080"

echo "=================================================="
echo " Starting Godot 4 All-in-One Cloud Server         "
echo " Web Client URL: http://0.0.0.0:${PUBLIC_PORT}    "
echo " Internal Godot Server Port: ${INTERNAL_PORT}     "
echo "=================================================="

# Generate Nginx configuration with the dynamic $PORT
export PORT="${PUBLIC_PORT}"
envsubst '${PORT}' < /etc/nginx/templates/default.conf.template > /etc/nginx/sites-available/default
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# Test Nginx configuration and start in background
nginx -t
nginx -g "daemon on;"

# Launch Godot dedicated server on internal port 8080
export PORT="${INTERNAL_PORT}"
exec godot --headless --path /app
