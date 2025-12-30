# SolixDB

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

## Docker Setup

### Quick Start with Parallel Indexers

1. **Start ClickHouse separately (with user configuration):**
```bash
# Start ClickHouse with custom users.xml
docker-compose -f docker-compose.clickhouse.yml up -d

# Or if ClickHouse is already running elsewhere, skip this step
```

2. **Generate parallel indexer configuration:**
```bash
chmod +x generate_parallel_indexers.sh

# Generate 4 indexers with auto-distributed slot ranges
./generate_parallel_indexers.sh 377107390 377107490 4

# Custom: 10 indexers, 2GB memory each, custom ClickHouse URL
CLICKHOUSE_URL=http://your-clickhouse-host:8123 ./generate_parallel_indexers.sh 377107390 383639270 10 2G
```

3. **Build the Docker image:**
```bash
docker build -t solixdb-indexer:latest .
```

4. **Start all indexers:**
```bash
docker-compose -f docker-compose.parallel.yml up -d
```

5. **Monitor logs:**
```bash
# All indexers (real-time)
docker-compose -f docker-compose.parallel.yml logs -f

# Specific indexer
docker-compose -f docker-compose.parallel.yml logs -f indexer-1

# Last 50 lines from all
docker-compose -f docker-compose.parallel.yml logs --tail 50
```

6. **Check status:**
```bash
# Check if containers are running/completed
docker ps -a --filter "name=indexer"

# Check container exit codes (0 = success)
docker ps -a --filter "name=indexer" --format "{{.Names}}\t{{.Status}}"

# Verify data in ClickHouse
docker exec clickhouse clickhouse-client --query "SELECT count() FROM transactions"
docker exec clickhouse clickhouse-client --query "SELECT protocol_name, count() FROM transactions GROUP BY protocol_name"
```

7. **Stop all indexers:**
```bash
# Stop containers (they auto-stop after completion anyway)
docker-compose -f docker-compose.parallel.yml down

# Stop and remove volumes (if needed)
docker-compose -f docker-compose.parallel.yml down -v
```

### Script Usage

```bash
./generate_parallel_indexers.sh <start_slot> <end_slot> <num_containers> [memory_per_container] [clickhouse_url]
```

**Arguments:**
- `start_slot`: Starting slot number (required)
- `end_slot`: Ending slot number (required)
- `num_containers`: Number of parallel indexers (1-100, default: 4)
- `memory_per_container`: Memory limit per container (default: 2G)
- `clickhouse_url`: ClickHouse URL (default: http://clickhouse:8123, or use CLICKHOUSE_URL env var)

**Example:**
```bash
# Process 1M slots across 10 containers (100k slots each)
./generate_parallel_indexers.sh 377107390 378107390 10 2G

# Process 6.5M slots across 32 containers (~200k slots each)
./generate_parallel_indexers.sh 377107390 383639270 32 4G
```

### ClickHouse Setup

ClickHouse is managed separately to allow custom user configuration:

```bash
# Start ClickHouse with custom users.xml (for password/auth)
docker-compose -f docker-compose.clickhouse.yml up -d

# Check ClickHouse is running
docker-compose -f docker-compose.clickhouse.yml ps

# View ClickHouse logs
docker-compose -f docker-compose.clickhouse.yml logs -f
```

**Configure users/passwords:** Edit `clickhouse-users.xml` before starting ClickHouse.

### Single Instance (Development)

```bash
# Build image
docker build -t solixdb-indexer:latest .

# Run standalone (assumes ClickHouse is running)
docker run -d --name indexer \
  -e SLOT_START=377107390 \
  -e SLOT_END=377107490 \
  -e THREADS=4 \
  -e CLICKHOUSE_URL=http://host.docker.internal:8123 \
  -e CLEAR_DB_ON_START=true \
  solixdb-indexer:latest
```

### Features

- **Auto-distributed slot ranges**: Script automatically divides slots evenly
- **No overlaps**: Each container processes unique slot ranges
- **Shared ClickHouse**: All indexers write to the same database (managed separately)
- **Resource limits**: Configurable memory per container
- **First container clears DB**: Only `indexer-1` sets `CLEAR_DB_ON_START=true`
- **Independent containers**: One failure doesn't affect others
- **Auto-stop on completion**: Containers exit after processing (no infinite restarts)
- **Network connectivity**: Indexers automatically connect to ClickHouse network

### Troubleshooting

**Containers can't connect to ClickHouse:**
```bash
# Verify ClickHouse is running
docker ps | grep clickhouse

# Check if ClickHouse is accessible
docker exec clickhouse wget -q -O- http://localhost:8123/ping

# Regenerate compose file to ensure network connectivity
./generate_parallel_indexers.sh <start> <end> <num>
docker-compose -f docker-compose.parallel.yml down
docker-compose -f docker-compose.parallel.yml up -d
```

**Containers keep restarting:**
- This is fixed! Containers now use `restart: "no"` and will stop after completion
- Check exit status: `docker ps -a --filter "name=indexer"`

**Check if data was written:**
```bash
# Connect to ClickHouse
docker exec -it clickhouse clickhouse-client

# Then run queries:
SELECT count() FROM transactions;
SELECT count() FROM transaction_payloads;
SELECT protocol_name, count() FROM transactions GROUP BY protocol_name;
```

**View detailed logs:**
```bash
# Check for errors
docker-compose -f docker-compose.parallel.yml logs | grep -i error

# Check processing progress
docker-compose -f docker-compose.parallel.yml logs | grep -i "slot\|success\|failed"
```

## Schema

### Tables

1. **transactions** - Fast analytics (metadata, metrics, time dimensions)
2. **transaction_payloads** - Full data (parsed_data, raw_data, logs) - compressed
3. **failed_transactions** - Parse failures for debugging

All tables use ZSTD(22) compression and are partitioned by month.

## Performance

- **Batched inserts**: 1000 rows per batch
- **Compression**: Automatic (ZSTD 22)
- **Parallel processing**: Configurable threads per instance
- **November 2025**: ~6.5M slots, process in hours with multiple instances

## Complete Workflow Example

```bash
# 1. Start ClickHouse
docker-compose -f docker-compose.clickhouse.yml up -d

# 2. Generate 4 indexers for 100 slots
./generate_parallel_indexers.sh 377107390 377107490 4

# 3. Build image (first time only)
docker build -t solixdb-indexer:latest .

# 4. Start all indexers
docker-compose -f docker-compose.parallel.yml up -d

# 5. Monitor progress
docker-compose -f docker-compose.parallel.yml logs -f

# 6. Verify completion (containers should show "Exited (0)")
docker ps -a --filter "name=indexer"

# 7. Check data in ClickHouse
docker exec clickhouse clickhouse-client --query "SELECT count() FROM transactions"

# 8. Clean up
docker-compose -f docker-compose.parallel.yml down
```

## Architecture

```
main.rs          → Entry point, firehose setup
multi_parser.rs  → Multi-protocol parser
storage.rs       → ClickHouse batched storage
helpers.rs       → Transaction processing & summary
```
