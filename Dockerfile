FROM debian:bookworm-slim

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Download and install Zig 0.16.0-dev (architecture-aware)
ARG ZIG_VERSION=0.16.0-dev.1484+d0ba6642b
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
    ZIG_ARCH="x86_64"; \
    elif [ "$ARCH" = "aarch64" ]; then \
    ZIG_ARCH="aarch64"; \
    else \
    echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    curl -L "https://ziglang.org/builds/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /usr/local && \
    ln -s /usr/local/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

# Verify installation
RUN zig version

WORKDIR /app

# Copy source
COPY . .

# Build with ReleaseFast
RUN zig build -Doptimize=ReleaseFast

# EXPOSE 8080 9001 9002

# Default: run load balancer with 4 workers
CMD ["./zig-out/bin/load_balancer_mp", "--workers", "4", "--port", "8080"]
