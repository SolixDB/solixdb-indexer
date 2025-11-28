# Jetstreamer Old Faithful with Raydium Parser

Example demonstrating how to fetch historical Solana blockchain data from Old Faithful and parse Raydium AMM v4 program instructions using Yellowstone Vixen parsers.

## Overview

This example shows how to stream historical Solana blocks and transactions from [Old Faithful](https://old-faithful.net/), filter for specific program interactions, and parse their instructions into structured data. It focuses on the Raydium AMM v4 program (`675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8`) and demonstrates how to:

- Stream historical blockchain data without running a full validator
- Filter transactions by program ID
- Resolve account keys from address lookup tables (ALTs)
- Parse program instructions into typed structures using Yellowstone Vixen parsers

## Features

- Stream blocks, transactions, entries, and rewards in real-time
- Filter transactions by target program ID
- Handle both legacy and versioned transactions (v0 with ALTs)
- Parse Raydium AMM v4 instructions into structured data
- Track processing statistics and program-specific transaction counts
- Graceful error handling for invalid account indices
- Configurable slot ranges and threading
- Built-in logging and progress tracking

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

The example will fetch blocks and transactions from slots 345000000 to 345000001 on Solana mainnet, filtering for Raydium AMM v4 program interactions.

### Configuration

Modify the configuration variables in `main.rs` to customize behavior:

```rust
let slot_start = 345000000;      // Starting slot
let slot_end = 345000001;        // Ending slot (exclusive)
let threads = 10;                // Number of processing threads
let network = "mainnet";         // Network: "mainnet", "testnet", or "devnet"
let compact_index_base_url = "https://files.old-faithful.net";
let network_capacity_mb = 100_000; // Network buffer capacity

// Target program to filter
let raydium_program_id = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"
    .parse::<Address>()
    .expect("Invalid program address");
```

### How It Works

1. **Block Streaming**: The firehose interface streams blocks from Old Faithful's historical archive
2. **Transaction Filtering**: Each transaction is checked for instructions that invoke the target program
3. **Account Resolution**: Account keys are resolved from both static keys and address lookup tables (ALTs)
4. **Instruction Parsing**: Raydium instructions are parsed using Yellowstone Vixen's typed parsers
5. **Statistics Tracking**: Counters track total transactions processed and program-specific matches

### What Gets Logged

- **Blocks**: Slot number, blockhash, transaction count, skipped slots
- **Transactions**: Signature, slot, index, vote status (all transactions)
- **Raydium Matches**: Transactions containing Raydium program instructions
- **Parsed Instructions**: Structured data from successfully parsed Raydium instructions
- **Errors**: Invalid account indices, parsing failures, firehose errors
- **Progress**: Processing updates every 100 transactions
- **Stats**: Periodic statistics every 1000 slots
- **Final Summary**: Total blocks, transactions, and Raydium matches

## Understanding the Code

### Account Resolution

Solana transactions can use Address Lookup Tables (ALTs) to compress account lists. The `build_full_account_list` function handles both transaction types:

- **Legacy transactions**: Use only static account keys
- **V0 transactions**: Combine static keys with dynamically loaded addresses from ALTs

### Instruction Filtering

The code filters instructions by:
1. Extracting the program ID index from each instruction
2. Resolving the actual program ID from the full account list
3. Comparing against the target program ID (Raydium)

### Parsing Flow

```rust
// 1. Build complete account list (static + ALT addresses)
let all_accounts = build_full_account_list(...);

// 2. Check if transaction uses target program
let uses_raydium = instructions.iter()
    .filter_map(|ix| all_accounts.get(ix.program_id_index as usize))
    .any(|program_id| *program_id == raydium_program_id);

// 3. Parse matching instructions
let instruction_update = InstructionUpdate {
    program: program_id.to_bytes().into(),
    data: ix.data.clone(),
    accounts: resolved_accounts,
    ...
};
raydium_parser.parse(&instruction_update).await?;
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
2025-11-28T20:57:36.203867Z  INFO Configuration loaded slot_start=345000000 slot_end=345000001 threads=1 network="mainnet" target_program=675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
2025-11-28T20:57:36.203993Z  INFO Starting data fetch from Old Faithful...
...
2025-11-28T20:58:17.459413Z  INFO Raydium parsed parsed=SwapBaseIn(SwapBaseIn { token_program: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA, amm: 5ja175UxNhHthD5AqubW3YaRBByY4mzmUB99ct8AXqot, amm_authority: 5Q544fKrFoe6tsEbD7S8EmxGTJYAKtTVhAW5Q5pge4j1, amm_open_orders: AKbXbb1ZsWTQRgXvjYrEEda8zeENMu8XBvzpcyeAYf9g, amm_target_orders: Some(4WzsKLVYBhesdYVtEi8Q58uYGGjXXgXgzshJCEgE15f7), pool_coin_token_account: J3vvjqCRp3HzPt299VA7Vry2U6HDDGoGNyTyCXXapiK3, pool_pc_token_account: 4yD3S8CYYSFRC8aXKgZFcPEaF7Ln38LbDPDktXAmaCuP, serum_program: srmqPvymJeFKQ4zGQed1GFppgkRHL9kaELCbyksJtPX, serum_market: HR1mJWDJz5AYoA1tHVdNdgTkojmX58UuYPtqRRdbbWjy, serum_bids: 3pVpFnYEpcyG6Yz1ZT9Hg1iauHtPzKrF1LaSQCrCByTt, serum_asks: 4wrbDU5pLHP94HYaS2JqDHAsdwD5Y7tjtUoAkFnMaZsc, serum_event_queue: 5eRFjEnCjiTWvZpfLngmCVBu2iBVyhVrbSDQWrSQQ4zo, serum_coin_vault_account: gw1P3B779yv7hG4Xs4NCS9JJioLGvbbDMRqYZiKS38F, serum_pc_vault_account: BoBo3i1uvFgkFn3iT4cBCBvmVm7PKmGM1ABkvgEstuD, serum_vault_signer: 9QBJ6wb9RbrweM1HuJCENN8dp3KRYDSBHnizbWg3Xjxz, uer_source_token_account: ExmCphHCbsCgbgPHPtsgZ8M1z5o8nZbiU26d4Siu6eZX, uer_destination_token_account: 2wMGLtMQMJN9DR1QPHasAUgWf48XXH5Hv3dwc7qUWtTj, user_source_owner: 84jMuw5srv5EQBdEUiDfrB9WKnxpyCizqvX3wWVj3cxR }, SwapBaseInInstructionArgs { amount_in: 9345425, minimum_amount_out: 1121 })
...
2025-11-28T20:58:17.461731Z  INFO Fetch completed successfully slot_start=345000000 slot_end=345000001 total_blocks=1 total_transactions=1707 processing_time_secs=8.6523295
2025-11-28T20:58:17.461737Z  INFO Raydium program transactions found: 30
2025-11-28T20:58:17.461740Z  INFO SUCCESS — Old Faithful data fetch is working!
```

## Troubleshooting

**RocksDB compilation errors**: Ensure you're using Clang 16 (not 17) and `LIBCLANG_PATH` is correctly set.

**Network errors**: The example includes retry logic and error handling. Check your network connection and Old Faithful service status.

**Invalid account index errors**: These occur when instruction account indices exceed the available account list. The code logs these errors and continues processing.

**Parsing errors**: If Raydium instructions fail to parse, the error is logged with details. This can happen with malformed instruction data or unsupported instruction types.

**Slot not found**: Some slots may be skipped or unavailable. These are logged as "Skipped slot" messages.

## Extending to Other Programs

To filter and parse different programs:

1. Change the target program ID:
```rust
let target_program_id = "YOUR_PROGRAM_ID_HERE"
    .parse::<Address>()
    .expect("Invalid program address");
```

2. Use the appropriate Yellowstone Vixen parser:
```rust
use yellowstone_vixen_your_program_parser::instructions_parser::InstructionParser;
let parser = Arc::new(InstructionParser);
```

3. Update the parsed instruction handling in the transaction handler

## Learn More

- [Old Faithful Archive](https://old-faithful.net/)
- [Yellowstone Vixen Parsers](https://github.com/rpcpool/yellowstone-vixen)
- [Raydium AMM Documentation](https://docs.raydium.io/)
- [Solana Address Lookup Tables](https://docs.solana.com/developing/lookup-tables)
- [Jetstreamer Documentation](https://docs.rs/jetstreamer-firehose)

## License

[MIT LICENSE](LICENSE)