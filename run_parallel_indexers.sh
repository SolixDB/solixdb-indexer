#!/bin/bash

# Run parallel indexers directly (without Docker)
# 
# This script automatically splits slot ranges across multiple processes.
# You only need to specify the total range - the script handles distribution!
#
# Usage: ./run_parallel_indexers.sh <start_slot> <end_slot> <num_processes> [threads_per_process] [clickhouse_url] [clear_db_on_start]
# 
# Examples:
#   ./run_parallel_indexers.sh 377107390 377107490 4
#   # Automatically splits 100 slots across 4 processes (25 slots each)
#
#   ./run_parallel_indexers.sh 377107390 377107490 4 8 http://clickhouse:8123
#   # 4 processes, 8 threads each, custom ClickHouse URL
#
#   ./run_parallel_indexers.sh 377107390 377107490 4 8 http://myuser:mystrongpassword@localhost:8123 true
#   # All processes will clear the database on start. Use "false" to prevent clearing.
#   # If omitted, first process clears DB (true), others don't (false)
#
# Note: Environment variables (SLOT_START, SLOT_END, etc.) override config.toml values
#       Each process gets its own slot range automatically calculated

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DEFAULT_START_SLOT=377107390
DEFAULT_END_SLOT=377107490
DEFAULT_NUM_PROCESSES=4
DEFAULT_THREADS=4

# Parse arguments
START_SLOT=${1:-$DEFAULT_START_SLOT}
END_SLOT=${2:-$DEFAULT_END_SLOT}
NUM_PROCESSES=${3:-$DEFAULT_NUM_PROCESSES}
THREADS_PER_PROCESS=${4:-$DEFAULT_THREADS}

# ClickHouse URL: use argument, then env var, then let config.toml handle it (don't set if not provided)
if [ -n "${5:-}" ]; then
    CLICKHOUSE_URL=$5
elif [ -n "${CLICKHOUSE_URL:-}" ]; then
    # Use existing env var
    CLICKHOUSE_URL=$CLICKHOUSE_URL
else
    # Don't set it - let config.toml or program defaults handle it
    CLICKHOUSE_URL=""
fi

# Clear DB on start: use argument if provided, otherwise use default behavior (first=true, others=false)
CLEAR_DB_OVERRIDE=${6:-""}

# Validate inputs
if ! [[ "$START_SLOT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: START_SLOT must be a number${NC}"
    exit 1
fi

if ! [[ "$END_SLOT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: END_SLOT must be a number${NC}"
    exit 1
fi

if ! [[ "$NUM_PROCESSES" =~ ^[0-9]+$ ]] || [ "$NUM_PROCESSES" -lt 1 ] || [ "$NUM_PROCESSES" -gt 100 ]; then
    echo -e "${RED}Error: NUM_PROCESSES must be between 1 and 100${NC}"
    exit 1
fi

if [ "$START_SLOT" -ge "$END_SLOT" ]; then
    echo -e "${RED}Error: START_SLOT ($START_SLOT) must be less than END_SLOT ($END_SLOT)${NC}"
    exit 1
fi

# Calculate slot distribution
TOTAL_SLOTS=$((END_SLOT - START_SLOT))
SLOTS_PER_PROCESS=$((TOTAL_SLOTS / NUM_PROCESSES))
REMAINDER=$((TOTAL_SLOTS % NUM_PROCESSES))

echo -e "${GREEN}Starting parallel indexers with automatic slot distribution${NC}"
echo -e "${YELLOW}Configuration:${NC}"
echo "  Total Slot Range: $START_SLOT to $END_SLOT ($TOTAL_SLOTS slots)"
echo "  Number of Processes: $NUM_PROCESSES"
echo "  Threads per Process: $THREADS_PER_PROCESS"
if [ -n "$CLICKHOUSE_URL" ]; then
    echo "  ClickHouse URL: $CLICKHOUSE_URL (overrides config.toml)"
else
    echo "  ClickHouse URL: (will use config.toml or default)"
fi
if [ -n "$CLEAR_DB_OVERRIDE" ]; then
    echo "  Clear DB on start: $CLEAR_DB_OVERRIDE (for all processes)"
else
    echo "  Clear DB on start: true (first process only), false (others)"
fi
echo ""
echo -e "${YELLOW}Automatic Slot Distribution:${NC}"
echo "  Base slots per process: $SLOTS_PER_PROCESS"
if [ $REMAINDER -gt 0 ]; then
    echo "  First $REMAINDER process(es) will get 1 extra slot"
fi
echo ""

# Check if binary exists, otherwise use cargo run
if [ -f "./target/release/transaction-parser" ]; then
    BINARY="./target/release/transaction-parser"
    USE_CARGO=false
elif [ -f "./target/debug/transaction-parser" ]; then
    BINARY="./target/debug/transaction-parser"
    USE_CARGO=false
else
    USE_CARGO=true
    echo -e "${YELLOW}Note: Binary not found, will use 'cargo run --release'${NC}"
    echo ""
fi

# Create logs directory
mkdir -p logs

# Start processes
CURRENT_SLOT=$START_SLOT
PIDS=()

for i in $(seq 1 $NUM_PROCESSES); do
    # Calculate slot range for this process
    if [ $i -le $REMAINDER ]; then
        # First REMAINDER processes get one extra slot
        PROCESS_SLOTS=$((SLOTS_PER_PROCESS + 1))
    else
        PROCESS_SLOTS=$SLOTS_PER_PROCESS
    fi
    
    PROCESS_START=$CURRENT_SLOT
    PROCESS_END=$((CURRENT_SLOT + PROCESS_SLOTS))
    
    # Determine CLEAR_DB_ON_START value
    if [ -n "$CLEAR_DB_OVERRIDE" ]; then
        # Use override value for all processes
        CLEAR_DB=$CLEAR_DB_OVERRIDE
    else
        # Default behavior: first process clears DB, others don't
        if [ $i -eq 1 ]; then
            CLEAR_DB="true"
        else
            CLEAR_DB="false"
        fi
    fi
    
    LOG_FILE="logs/indexer-${i}.log"
    
    echo -e "${GREEN}  → indexer-${i}:${NC} slots ${PROCESS_START} to ${PROCESS_END} (${PROCESS_SLOTS} slots) [CLEAR_DB_ON_START=${CLEAR_DB}]"
    
    # Set environment variables and run
    if [ "$USE_CARGO" = true ]; then
        (
            export SLOT_START=$PROCESS_START
            export SLOT_END=$PROCESS_END
            export THREADS=$THREADS_PER_PROCESS
            export CLICKHOUSE_URL=$CLICKHOUSE_URL
            export CLEAR_DB_ON_START=$CLEAR_DB
            cargo run --release > "$LOG_FILE" 2>&1
        ) &
    else
        (
            export SLOT_START=$PROCESS_START
            export SLOT_END=$PROCESS_END
            export THREADS=$THREADS_PER_PROCESS
            export CLICKHOUSE_URL=$CLICKHOUSE_URL
            export CLEAR_DB_ON_START=$CLEAR_DB
            $BINARY > "$LOG_FILE" 2>&1
        ) &
    fi
    
    PIDS+=($!)
    
    CURRENT_SLOT=$PROCESS_END
    
    # Small delay to avoid race conditions
    sleep 0.5
done

echo ""
echo -e "${GREEN}✓ Started ${NUM_PROCESSES} indexer processes${NC}"
echo -e "${YELLOW}Process IDs:${NC} ${PIDS[*]}"
echo ""
echo -e "${YELLOW}Each process will:${NC}"
echo "  • Process its assigned slot range automatically"
echo "  • Write to the same ClickHouse instance"
echo "  • Create its own log file"
echo ""
echo -e "${YELLOW}Log files:${NC}"
for i in $(seq 1 $NUM_PROCESSES); do
    echo "  logs/indexer-${i}.log"
done
echo ""
echo -e "${YELLOW}Monitor progress:${NC}"
echo "  # Watch all logs in real-time"
echo "  tail -f logs/indexer-*.log"
echo ""
echo "  # Watch specific indexer"
echo "  tail -f logs/indexer-1.log"
echo ""
echo "  # Check running processes"
echo "  ps aux | grep transaction-parser"
echo ""
echo -e "${YELLOW}Stop all processes:${NC}"
echo "  pkill -f transaction-parser"
echo "  # Or individually: kill ${PIDS[*]}"
echo ""
echo -e "${YELLOW}Note:${NC} Each process uses config.toml (if present) but environment variables override it."
echo "      Slot ranges are set via environment variables for each process."
echo ""

# Wait for all processes to complete
echo -e "${YELLOW}Waiting for all processes to complete...${NC}"
echo ""

FAILED=0
for i in "${!PIDS[@]}"; do
    PID=${PIDS[$i]}
    INDEXER_NUM=$((i + 1))
    if wait $PID; then
        echo -e "${GREEN}✓ indexer-${INDEXER_NUM} (PID $PID) completed successfully${NC}"
    else
        EXIT_CODE=$?
        echo -e "${RED}✗ indexer-${INDEXER_NUM} (PID $PID) failed with exit code $EXIT_CODE${NC}"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All indexers completed successfully!${NC}"
    echo ""
    echo -e "${YELLOW}Check data in ClickHouse:${NC}"
    echo "  # If ClickHouse is accessible, you can query:"
    echo "  # SELECT count() FROM transactions;"
    exit 0
else
    echo -e "${RED}✗ $FAILED indexer(s) failed${NC}"
    echo -e "${YELLOW}Check logs for details:${NC}"
    for i in $(seq 1 $NUM_PROCESSES); do
        if [ -f "logs/indexer-${i}.log" ]; then
            echo "  logs/indexer-${i}.log"
        fi
    done
    exit 1
fi

