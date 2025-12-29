# SolixDB Data Collection

High-performance Solana blockchain data collection system for analytics platform.

## Features

- **Multi-protocol parsing**: Pumpfun, Jupiter, Raydium, Orca
- **Batched inserts**: Efficient ClickHouse writes (1000 rows/batch)
- **Maximum compression**: ZSTD(22) on all fields
- **Docker-ready**: Parallel collection with multiple instances
- **Configurable**: Environment variables for all settings

## Quick Start

### Test with 1k slots
```bash
cargo run
```

### Custom slot range
```bash
SLOT_START=377107390 SLOT_END=377108390 cargo run
```

### November 2025 data (Nov 1 - Dec 1)
```bash
SLOT_START=377107390 SLOT_END=383639270 THREADS=10 cargo run
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SLOT_START` | `377107390` | Starting slot (Nov 1, 2025 0:00 UTC) |
| `SLOT_END` | `377108390` | Ending slot (1k slots for testing) |
| `THREADS` | `10` | Number of parallel threads |
| `CLICKHOUSE_URL` | `http://localhost:8123` | ClickHouse server URL |
| `NETWORK` | `mainnet` | Solana network |
| `CLEAR_DB_ON_START` | `true` | Clear database on startup |
| `CLEAR_DATA_AFTER` | `false` | Clear data after processing |

## Testing Docker

### Build and Test
```bash
chmod +x test_docker.sh

# Test with default slots (1k slots)
./test_docker.sh

# Test with custom slots
./test_docker.sh 377107390 377108390

# Test October 2025 (use your own slot numbers)
./test_docker.sh <OCT_START_SLOT> <OCT_END_SLOT>
```

### Run Single Instance
```bash
# Build first
docker build -t solixdb-collector:latest .

# Run with your slots
docker run -d --name collector \
  -e SLOT_START=<YOUR_START_SLOT> \
  -e SLOT_END=<YOUR_END_SLOT> \
  -e THREADS=10 \
  -e CLICKHOUSE_URL=http://host.docker.internal:8123 \
  solixdb-collector:latest
```

### Scale Up (Production)
```bash
# Generate docker-compose.yml with custom slots
./generate_collectors.sh 32 <SLOT_START> <SLOT_END>

# Example: November 2025
./generate_collectors.sh 32 377107390 383639270

# Start all collectors
docker-compose up -d
```

## Docker Details

**Build once, run many**: Docker builds the image **once** (~10-15GB) and reuses it for all collectors.

**Disk usage**: ~10-15GB total (not multiplied by number of collectors).

## Schema

### Tables

1. **transactions** - Fast analytics (metadata, metrics, time dimensions)
2. **transaction_payloads** - Full data (parsed_data, raw_data, logs) - compressed
3. **protocol_events** - Normalized protocol data (amounts, prices, users)
4. **failed_transactions** - Parse failures for debugging

All tables use ZSTD(22) compression and are partitioned by month.

## Performance

- **Batched inserts**: 1000 rows per batch
- **Compression**: Automatic (ZSTD 22)
- **Parallel processing**: Configurable threads per instance
- **November 2025**: ~6.5M slots, process in hours with multiple instances

## Architecture

```
main.rs          → Entry point, firehose setup
parser.rs        → Multi-protocol parser
clickhouse.rs    → Batched storage
types.rs         → Data structures
```
