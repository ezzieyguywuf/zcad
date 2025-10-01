# Base image
FROM ubuntu:latest

# Set DEBIAN_FRONTEND to noninteractive to avoid prompts during apt-get install
ENV DEBIAN_FRONTEND=noninteractive

# Install essential build tools and dependencies
# Note: minisign and jq are used for fetching/validating zig nightly precompiled
# binary
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    xz-utils \
    git \
    wget \
    ca-certificates \
    gnupg \
    pkg-config \
    libwayland-dev \
    wayland-protocols \
    libvulkan-dev \
    libx11-dev \
    glslc \
    minisign \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Copy the Zig download script into the image
COPY docker/download_zig.sh /usr/local/bin/download_zig
# Install both versions of Zig and set up symlinks in a single layer
RUN chmod +x /usr/local/bin/download_zig && \
    download_zig '0.15.1' '/opt/zig-0.15.1' && \
    download_zig 'master' '/opt/zig-master' && \
    ln -s /opt/zig-master/zig /usr/local/bin/zig && \
    ln -s /opt/zig-0.15.1/zig /usr/local/bin/zig-0.15.1

# Set working directory
WORKDIR /app

# Verify installations
RUN zig version && \
    zig-0.15.1 version && \
    if command -v glslc &> /dev/null; then glslc --version; else echo "glslc not found directly, check shaderc or other packages"; fi