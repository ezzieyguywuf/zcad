# Base image
FROM ubuntu:latest

# Set DEBIAN_FRONTEND to noninteractive to avoid prompts during apt-get install
ENV DEBIAN_FRONTEND=noninteractive

# Install essential build tools and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    xz-utils \
    git \
    wget \
    ca-certificates \
    gnupg \
    # Attempt to install glslc directly or via shaderc package
    # If glslc is not found, the build might fail here, requiring a different approach for glslc
    glslc \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.14.0
ARG ZIG_VERSION=0.14.0
ARG ZIG_TARGET_ARCH=x86_64
ARG ZIG_TARGET_OS=linux
RUN mkdir -p /usr/local/zig_install && \
    cd /usr/local/zig_install && \
    wget -O zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_TARGET_OS}-${ZIG_TARGET_ARCH}-${ZIG_VERSION}.tar.xz" && \
    tar -xf zig.tar.xz --strip-components=1 && \
    mv /usr/local/zig_install /usr/local/zig && \
    ln -s /usr/local/zig/zig /usr/local/bin/zig && \
    rm -rf /usr/local/zig_install

# Set working directory
WORKDIR /app

# Verify installations (optional, but good for debugging Dockerfile)
RUN zig version
RUN if command -v glslc &> /dev/null; then glslc --version; else echo "glslc not found directly, check shaderc or other packages"; fi

# Default command (optional)
# CMD ["/bin/bash"]
