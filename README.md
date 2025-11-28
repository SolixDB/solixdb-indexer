# Jetstreamer Old Faithful Example

Example demonstrating how to fetch and process historical Solana blockchain data from Old Faithful using Jetstreamer's firehose interface.

## Overview

This example shows how to stream historical Solana blocks, transactions, entries, and rewards data from [Old Faithful](https://old-faithful.net/), an open-source archive of all Solana blocks and transactions from genesis to the current chain tip. The firehose interface provides a simple, efficient way to access historical data without running a full validator node.

## Features

- Stream blocks, transactions, entries, and rewards in real-time
- Handle skipped slots and network errors gracefully
- Track processing statistics and progress
- Configurable slot ranges and threading
- Built-in logging and error handling

## Prerequisites

Jetstreamer requires **Clang 16** (not 17) due to RocksDB dependencies.

### Linux (Ubuntu/Debian)

```bash
# Install Clang 16
wget -qO- https://apt.llvm.org/llvm.sh | sudo bash -s -- 16
sudo apt update && sudo apt install -y gcc-13 g++-13 zlib1g-dev libssl-dev libtool

# Set as default
sudo update-alternatives --install /usr/bin/clang clang /usr/bin/clang-16 100
sudo update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-16 100

# Environment variables (add to ~/.bashrc)
export CC=clang
export CXX=clang++
export LIBCLANG_PATH=/usr/lib/llvm16/lib/libclang.so
```

### Linux (Arch)

```bash
sudo pacman -S clang16 llvm16 zlib openssl libtool
yay -S gcc13  # or use system gcc

# Environment variables (add to ~/.bashrc)
export CC=clang-16
export CXX=clang++-16
export LIBCLANG_PATH=/usr/lib/llvm16/lib/libclang.so
export LD_LIBRARY_PATH=/usr/lib/llvm16/lib:$LD_LIBRARY_PATH
```

### macOS

```bash
brew install llvm@16 zlib openssl libtool

# Environment variables (add to ~/.zshrc)
export CC=/opt/homebrew/opt/llvm@16/bin/clang
export CXX=/opt/homebrew/opt/llvm@16/bin/clang++
export LIBCLANG_PATH=/opt/homebrew/opt/llvm@16/lib/libclang.dylib
export LDFLAGS="-L/opt/homebrew/opt/llvm@16/lib"
export CPPFLAGS="-I/opt/homebrew/opt/llvm@16/include"
```

## Installation

Clone this repository and build:

```bash
cargo build --release
```

## Usage

Run the example with default configuration:

```bash
cargo run --release
```

The example will fetch blocks and transactions from slots 325000000 to 325000001 on Solana mainnet.

### Configuration

Modify the configuration variables in `main.rs` to customize behavior:

```rust
let slot_start = 325000000;      // Starting slot
let slot_end = 325000001;        // Ending slot (exclusive)
let threads = 1;                 // Number of processing threads
let network = "mainnet";         // Network: "mainnet", "testnet", or "devnet"
let compact_index_base_url = "https://files.old-faithful.net";
let network_capacity_mb = 100_000; // Network buffer capacity
```

### What Gets Logged

The example logs the following data types:

- **Blocks**: Slot number, blockhash, transaction count
- **Transactions**: Signature, slot, index, vote status
- **Entries**: Slot, entry index, number of hashes, entry hash
- **Rewards**: Slot, number of rewards distributed
- **Stats**: Periodic processing statistics (every 1000 slots)
- **Errors**: Any errors encountered during processing

## Epoch Feature Availability

Old Faithful ledger snapshots vary in available metadata due to Solana's evolution:

| Epoch | Slot        | Notes |
|-------|-------------|-------|
| 0-156 | 0-?         | Incompatible with modern Geyser plugins |
| 157+  | ?           | Compatible with modern Geyser plugins |
| 0-449 | 0-194184610 | CU tracking not available (reported as 0) |
| 450+  | 194184611+  | CU tracking available |

The firehose interface in this example works with all epochs, including those incompatible with Geyser plugins.

## Output Example

```
2025-11-28T13:06:48.060661Z  INFO Starting Old Faithful transaction logger
2025-11-28T13:06:48.060736Z  INFO Configuration loaded slot_start=325000000 slot_end=325000001 threads=1 network="mainnet"
2025-11-28T13:06:48.060838Z  INFO Starting data fetch from Old Faithful...
2025-11-28T13:06:48.065086Z  INFO starting firehose...
2025-11-28T13:06:48.065734Z  INFO index base url: https://files.old-faithful.net/
2025-11-28T13:06:48.065811Z  INFO Generated 1 thread ranges covering 1 slots total
2025-11-28T13:06:48.066203Z  INFO slot range: 325000000 (epoch 752) ... 325000001 (epoch 752)
2025-11-28T13:06:48.066218Z  INFO 🚒 starting firehose...
2025-11-28T13:06:48.066238Z  INFO entering epoch 752
...
2025-11-28T13:06:59.538983Z  INFO Fetch completed successfully slot_start=325000000 slot_end=325000001 total_blocks=1 total_transactions=2043 processing_time_secs=11.478109
2025-11-28T13:06:59.538991Z  INFO SUCCESS — Old Faithful data fetch is working!
```

## Troubleshooting

**RocksDB compilation errors**: Ensure you're using Clang 16 (not 17) and `LIBCLANG_PATH` is correctly set.

**Network errors**: The example includes retry logic and error handling. Check your network connection and the Old Faithful service status.

**Slot not found**: Some slots may be skipped or unavailable. The example logs these as "Skipped slot" messages.

## Dependencies

```toml
[dependencies]
futures-util = "0.3.31"
jetstreamer-firehose = "0.2.0"
jetstreamer-plugin = "0.2.0"
jetstreamer-utils = "0.2.0"
solana-hash = { version = "3.0.0", features = ["serde"] }
solana-sdk = "2.2.0"
solana-sysvar = { version = "3.0.0", features = ["serde"] }
tokio = { version = "1.48.0", features = ["macros"] }
tracing = "0.1.43"
tracing-subscriber = "0.3.22"
```

## Learn More

- [Old Faithful Archive](https://old-faithful.net/)
- [Project Yellowstone](https://github.com/rpcpool/yellowstone-grpc)
- [Jetstreamer Documentation](https://docs.rs/jetstreamer-firehose)

## License
[MIT LICENSE](LICENSE)