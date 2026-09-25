FROM ubuntu:22.04

# Prevent interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies required by Godot 4 headless
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    unzip \
    libfontconfig1 \
    libxcursor1 \
    libxinerama1 \
    libxrandr2 \
    libxi6 \
    libasound2 \
    libgl1 \
    libpulse0 \
    libudev1 \
    && rm -rf /var/lib/apt/lists/*

# Install Godot 4.3 stable Linux x86_64 binary
ARG GODOT_VERSION=4.3
ARG GODOT_RELEASE=stable
RUN wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-${GODOT_RELEASE}/Godot_v${GODOT_VERSION}-${GODOT_RELEASE}_linux.x86_64.zip" -O /tmp/godot.zip \
    && unzip -q /tmp/godot.zip -d /usr/local/bin \
    && mv /usr/local/bin/Godot_v${GODOT_VERSION}-${GODOT_RELEASE}_linux.x86_64 /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm /tmp/godot.zip

# Create application directory
WORKDIR /app

# Copy project files
COPY . /app

# Ensure entrypoint script is executable
RUN chmod +x /app/entrypoint.sh

# Initial headless editor import to pre-cache imported assets
RUN godot --headless --editor --quit || true

# Render default port
ENV PORT=10000
EXPOSE 10000

# Start headless server
ENTRYPOINT ["/app/entrypoint.sh"]
