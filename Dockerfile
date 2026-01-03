# Multi-stage Dockerfile for optimized Rust build with clang16 (required for rocksdb)
FROM ubuntu:24.04 AS builder

WORKDIR /app

# Install Rust + build dependencies
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    build-essential \
    pkg-config \
    libssl-dev \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.cargo/bin:${PATH}"

# Install LLVM 16 (required for rocksdb)
RUN apt-get update && apt-get install -y \
    wget \
    gnupg \
    ca-certificates \
    && wget -O /tmp/llvm-snapshot.gpg.key https://apt.llvm.org/llvm-snapshot.gpg.key \
    && gpg --dearmor < /tmp/llvm-snapshot.gpg.key > /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/jammy/ llvm-toolchain-jammy-16 main" \
        > /etc/apt/sources.list.d/llvm16.list \
    && apt-get update && apt-get install -y \
    clang-16 \
    libclang-16-dev \
    && rm -rf /var/lib/apt/lists/* /tmp/llvm-snapshot.gpg.key

ENV CC=clang-16
ENV CXX=clang++-16
ENV LIBCLANG_PATH=/usr/lib/llvm-16/lib
ENV LDFLAGS="-L/usr/lib/llvm-16/lib"
ENV CPPFLAGS="-I/usr/lib/llvm-16/include"
ENV PATH="/usr/lib/llvm-16/bin:${PATH}"

# Copy dependency files first for better caching
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY idls ./idls

# Create a dummy src/main.rs to build dependencies
RUN mkdir -p src && \
    echo "fn main() {}" > src/main.rs && \
    cargo build --release && \
    rm -rf src

# Copy actual source code
COPY src ./src

# Build the actual application
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release && \
    cp /app/target/release/solixdb-indexer /app/solixdb-indexer

# Runtime stage
FROM ubuntu:24.04

WORKDIR /app

# Install only runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Copy binary from builder
COPY --from=builder /app/solixdb-indexer /app/solixdb-indexer

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD pgrep -f solixdb-indexer || exit 1

# Run the application
ENTRYPOINT ["/app/solixdb-indexer"]
