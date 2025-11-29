# Jetstreamer Old Faithful Multi-Parser Example

Example demonstrating how to fetch historical Solana blockchain data from Old Faithful and parse multiple program instructions simultaneously using Yellowstone Vixen parsers.

## Overview

This example shows how to stream historical Solana blocks and transactions from [Old Faithful](https://old-faithful.net/), filter for multiple program interactions simultaneously, and parse their instructions into structured data. It demonstrates a scalable multi-parser architecture that can monitor and parse transactions from any number of Solana programs concurrently.

The example includes parsers for popular Solana programs including:
- **Pumpfun** - Token launch platform
- **Pumpfun Swaps** - Swap functionality
- **Raydium** - AMM V4, CLMM, CPMM, and Launchpad
- **Jupiter** - Aggregated swaps
- **Meteora** - AMM launchpad
- **Moonshot** - Launchpad platform
- **Orca Whirlpool** - Concentrated liquidity pools

## Key Features

- **Multi-Parser Architecture**: Monitor and parse multiple programs simultaneously with a single stream
- **Scalable Design**: Easily add or remove parsers for different programs
- **Transaction Statistics**: Track parsing counts per program with atomic counters
- **Stream historical blockchain data** without running a full validator
- **Filter transactions** by multiple program IDs concurrently
- **Resolve account keys** from address lookup tables (ALTs)
- **Parse program instructions** into typed structures using Yellowstone Vixen parsers
- **Graceful error handling** for invalid account indices and parsing failures
- **Configurable slot ranges** and threading
- **Built-in logging** and progress tracking

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

The example will fetch blocks and transactions from slots 345000000 to 345000100 on Solana mainnet, filtering for all configured program interactions.

### Configuration

Modify the configuration variables in `main.rs` to customize behavior:

```rust
let slot_start = 345000000;      // Starting slot
let slot_end = 345000100;        // Ending slot (exclusive)
let threads = 1;                 // Number of processing threads
let network = "mainnet";         // Network: "mainnet", "testnet", or "devnet"
let compact_index_base_url = "https://files.old-faithful.net";
let network_capacity_mb = 100_000; // Network buffer capacity
```

### Multi-Parser Setup

The multi-parser architecture allows you to monitor multiple programs simultaneously:

```rust
let multi_parser = MultiParser::new()
    .add_parser(
        "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P",
        "Pumpfun",
        PumpfunIxParser,
    )
    .add_parser(
        "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
        "Raydium AMM V4",
        RaydiumAmmV4IxParser,
    )
    .add_parser(
        "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4",
        "Jupiter Swaps",
        JupiterSwapIxParser,
    );
    // Add more parsers as needed
```

### How It Works

1. **Block Streaming**: The firehose interface streams blocks from Old Faithful's historical archive
2. **Transaction Processing**: Each transaction is examined for instructions from any monitored program
3. **Account Resolution**: Account keys are resolved from both static keys and address lookup tables (ALTs)
4. **Multi-Parser Routing**: Instructions are automatically routed to the appropriate parser based on program ID
5. **Instruction Parsing**: Each parser converts raw instruction data into typed structures
6. **Statistics Tracking**: Atomic counters track parsing counts per program
7. **Summary Reporting**: Final statistics show transaction counts for each parser

### What Gets Logged

- **Configuration**: Active parsers and their program IDs at startup
- **Progress Updates**: Processing statistics every 10,000 slots
- **Parsed Instructions**: Successfully parsed instruction data with parser name, signature, and slot
- **Parse Errors**: Failed parsing attempts with error details
- **Firehose Errors**: Network or streaming errors with context
- **Final Summary**: Transaction counts per parser at completion

## Understanding the Code

### Multi-Parser Architecture

The `MultiParser` struct manages multiple parsers efficiently:

```rust
pub struct MultiParser {
    parsers: HashMap<Address, ParserEntry>,
}

struct ParserEntry {
    name: &'static str,
    parser: Arc<dyn ParserTrait>,
    counter: AtomicU64,
}
```

Key features:
- **HashMap lookup**: O(1) parser retrieval by program ID
- **Arc-wrapped parsers**: Safe sharing across async tasks
- **Atomic counters**: Thread-safe transaction counting per parser
- **Dynamic dispatch**: Generic parser trait for any Yellowstone Vixen parser

### Parser Trait

The `ParserTrait` provides a unified interface for all parsers:

```rust
trait ParserTrait: Send + Sync {
    fn parse_and_log<'a>(
        &'a self,
        instruction: &'a InstructionUpdate,
        parser_name: &'a str,
        signature: &'a str,
        slot: u64,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>>;
}
```

This trait is automatically implemented for any Yellowstone Vixen parser with a debuggable output type.

### Account Resolution

Solana transactions can use Address Lookup Tables (ALTs) to compress account lists. The `build_full_account_list` function handles both transaction types:

- **Legacy transactions**: Use only static account keys
- **V0 transactions**: Combine static keys with dynamically loaded addresses from ALTs

### Transaction Processing Flow

```rust
// 1. Build complete account list (static + ALT addresses)
let all_accounts = build_full_account_list(...);

// 2. Process each instruction in the transaction
for ix in instructions {
    let program_id = all_accounts[ix.program_id_index];
    
    // 3. Check if we have a parser for this program
    if !multi_parser.has_parser(&program_id) {
        continue;
    }
    
    // 4. Resolve instruction accounts
    let resolved_accounts: Vec<_> = ix.accounts
        .iter()
        .filter_map(|idx| all_accounts.get(*idx as usize))
        .map(|addr| addr.to_bytes().into())
        .collect();
    
    // 5. Parse and log the instruction
    multi_parser.parse_instruction(
        &program_id,
        &instruction_update,
        &signature,
        slot,
    ).await;
}
```

## Epoch Feature Availability

Old Faithful ledger snapshots vary in available metadata due to Solana's evolution:

| Epoch | Slot        | Notes |
|-------|-------------|-------|
| 0-156 | 0-?         | Incompatible with modern Geyser plugins |
| 157+  | ?           | Compatible with modern Geyser plugins |
| 0-449 | 0-194184610 | CU tracking not available (reported as 0) |
| 450+  | 194184611+  | CU tracking available |

The firehose interface works with all epochs, including those incompatible with Geyser plugins.

## Output Example

```
2025-11-29T08:25:38.316056Z  INFO Starting Multi-Parser Transaction Logger
2025-11-29T08:25:38.316300Z  INFO Active parsers:
2025-11-29T08:25:38.316335Z  INFO   - Pumpfun (6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P)
2025-11-29T08:25:38.316343Z  INFO   - Moonshot Launchpad (MoonCVVNZFSYkqNXP6bxHLPL6QQJiMagDL3qcqUQTrG)
2025-11-29T08:25:38.316350Z  INFO   - Orca Whirlpool Launchpad (whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc)
2025-11-29T08:25:38.316358Z  INFO   - Raydium CLMM (CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK)
2025-11-29T08:25:38.316364Z  INFO   - Raydium AMM V4 (675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8)
2025-11-29T08:25:38.316371Z  INFO   - Jupiter Swaps (JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4)
2025-11-29T08:25:38.316378Z  INFO   - Raydium CPMM (CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C)
2025-11-29T08:25:38.316384Z  INFO   - Pumpfun Swaps (pAMMBay6oceH9fJKBRHGP5D4bD4sWpmSwMn52FMfXEA)
2025-11-29T08:25:38.316391Z  INFO   - Raydium Launchpad (LanMV9sAd7wArD4vJFi2qDdfnVhFxYSUg6eADduJ3uj)
2025-11-29T08:25:38.316398Z  INFO   - Meteora AMM Launchpad (cpamdpZCGKUy5JxQXB4dcpGPiikHawvSWAd6mEn1sGG)
2025-11-29T08:25:38.316417Z  INFO Configuration loaded slot_start=345000000 slot_end=345000100 threads=1 network="mainnet" parser_count=10
2025-11-29T08:25:38.316477Z  INFO Starting data fetch from Old Faithful...
2025-11-29T08:25:38.319682Z  INFO starting firehose...
...
2025-11-29T08:26:29.456893Z  INFO Instruction parsed parser="Raydium AMM V4" signature="5LLzfmpEoZuSsFGzzxT8u4TkXMqkV1Rn3QJMpmr6UzyRFocXU7KBZs64PDHNk6muksc19AxPyKVxuNeiuxtinK2A" slot=345000099 parsed=SwapBaseIn(SwapBaseIn { ... })
2025-11-29T08:26:29.458379Z  INFO Instruction parsed parser="Pumpfun Swaps" signature="4aVixJupzQXWHTUN7xCt9ZwTBikyxeWEa1DVSAdjspQkp2GfvAj6SZrqzfEh1LjSD5Pd2TXDPaWdqTnj3FgTvXJg" slot=345000099 parsed=Sell(Sell { ... })
...
2025-11-29T08:26:29.459268Z  INFO Processing completed slot_range="345000000-345000100" duration_secs=51.142629416
2025-11-29T08:26:29.459274Z  INFO Transaction counts by parser:
2025-11-29T08:26:29.459277Z  INFO   - Pumpfun: 1357 transactions
2025-11-29T08:26:29.459280Z  INFO   - Moonshot Launchpad: 1 transactions
2025-11-29T08:26:29.459283Z  INFO   - Orca Whirlpool Launchpad: 78 transactions
2025-11-29T08:26:29.459285Z  INFO   - Raydium CLMM: 1489 transactions
2025-11-29T08:26:29.459287Z  INFO   - Raydium AMM V4: 5259 transactions
2025-11-29T08:26:29.459289Z  INFO   - Jupiter Swaps: 2700 transactions
2025-11-29T08:26:29.459291Z  INFO   - Raydium CPMM: 177 transactions
2025-11-29T08:26:29.459294Z  INFO   - Pumpfun Swaps: 5330 transactions
2025-11-29T08:26:29.459297Z  INFO   - Raydium Launchpad: 9 transactions
2025-11-29T08:26:29.459299Z  INFO   - Meteora AMM Launchpad: 15 transactions
```

## Adding New Parsers

To add a new program parser:

1. **Add the parser dependency** to `Cargo.toml`:
```toml
yellowstone-vixen-your-program-parser = "0.1.0"
```

2. **Import the parser** in `main.rs`:
```rust
use yellowstone_vixen_your_program_parser::instructions_parser::InstructionParser as YourProgramIxParser;
```

3. **Register with MultiParser**:
```rust
let multi_parser = MultiParser::new()
    // ... existing parsers ...
    .add_parser(
        "YOUR_PROGRAM_ID_HERE",
        "Your Program Name",
        YourProgramIxParser,
    );
```

That's it! The multi-parser will automatically route and parse instructions from your new program.

## Removing Parsers

Simply comment out or remove the `.add_parser()` call for any parser you don't need. The system will skip instructions from that program without any performance impact.

## Troubleshooting

**RocksDB compilation errors**: Ensure you're using Clang 16 (not 17) and `LIBCLANG_PATH` is correctly set.

**Network errors**: The example includes retry logic and error handling. Check your network connection and Old Faithful service status.

**Invalid account index errors**: These occur when instruction account indices exceed the available account list. The code logs these errors and continues processing.

**Parsing errors**: If instructions fail to parse, the error is logged with parser name and details. This can happen with malformed instruction data or unsupported instruction types.

**Slot not found**: Some slots may be skipped or unavailable. These are logged as "Firehose error" messages.

**Parser not found**: If you see instructions being skipped, verify that the program ID is correctly registered in the multi-parser setup.

## Performance Considerations

- **Memory Usage**: Each parser maintains atomic counters. With 10 parsers, overhead is minimal (<1KB)
- **Lookup Performance**: HashMap lookups are O(1), making program ID matching very fast
- **Thread Safety**: All parsers are thread-safe and can be used across multiple processing threads
- **Async Processing**: Parsing happens asynchronously, allowing concurrent processing of multiple instructions

## Learn More

- [Old Faithful Archive](https://old-faithful.net/)
- [Yellowstone Vixen Parsers](https://github.com/rpcpool/yellowstone-vixen)
- [Raydium AMM Documentation](https://docs.raydium.io/)
- [Jupiter Aggregator](https://jup.ag/)
- [Solana Address Lookup Tables](https://docs.solana.com/developing/lookup-tables)
- [Jetstreamer Documentation](https://docs.rs/jetstreamer-firehose)

## License

[MIT LICENSE](LICENSE)