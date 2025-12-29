FROM ubuntu:24.04 AS builder

WORKDIR /app

# Rust + build deps
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    build-essential \
    pkg-config \
    libssl-dev \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.cargo/bin:${PATH}"

# LLVM 16 (via jammy repo)
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

COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY src ./src

RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release && \
    cp /app/target/release/transaction-parser /app/transaction-parser

# Runtime stage
FROM ubuntu:24.04

WORKDIR /app

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy binary from builder stage
COPY --from=builder /app/transaction-parser /app/transaction-parser

# Run the application
ENTRYPOINT ["/app/transaction-parser"]
