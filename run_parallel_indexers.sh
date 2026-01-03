#!/bin/bash
# This file was AI generated

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DEFAULT_START_SLOT=377107390
DEFAULT_END_SLOT=377107490
DEFAULT_NUM_PROCESSES=4
DEFAULT_THREADS=4

START_SLOT=${1:-$DEFAULT_START_SLOT}
END_SLOT=${2:-$DEFAULT_END_SLOT}
NUM_PROCESSES=${3:-$DEFAULT_NUM_PROCESSES}
THREADS_PER_PROCESS=${4:-$DEFAULT_THREADS}

if [ -n "${5:-}" ]; then
    CLICKHOUSE_URL=$5
elif [ -n "${CLICKHOUSE_URL:-}" ]; then
    CLICKHOUSE_URL=$CLICKHOUSE_URL
else
    CLICKHOUSE_URL=""
fi

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

TOTAL_SLOTS=$((END_SLOT - START_SLOT))
SLOTS_PER_PROCESS=$((TOTAL_SLOTS / NUM_PROCESSES))
REMAINDER=$((TOTAL_SLOTS % NUM_PROCESSES))

echo -e "${GREEN}Starting $NUM_PROCESSES indexers${NC}"
echo "Range: $START_SLOT-$END_SLOT ($TOTAL_SLOTS slots, $SLOTS_PER_PROCESS per process)"
echo "Threads: $THREADS_PER_PROCESS per process"
echo ""

if [ -f "$SCRIPT_DIR/target/release/solixdb-indexer" ]; then
    BINARY="$SCRIPT_DIR/target/release/solixdb-indexer"
    USE_CARGO=false
elif [ -f "$SCRIPT_DIR/target/debug/solixdb-indexer" ]; then
    BINARY="$SCRIPT_DIR/target/debug/solixdb-indexer"
    USE_CARGO=false
else
    USE_CARGO=true
    echo -e "${YELLOW}Note: Binary not found, will use 'cargo run --release'${NC}"
    echo ""
fi

mkdir -p "$SCRIPT_DIR/logs"

CURRENT_SLOT=$START_SLOT
PIDS=()

for i in $(seq 1 $NUM_PROCESSES); do
    if [ $i -le $REMAINDER ]; then
        PROCESS_SLOTS=$((SLOTS_PER_PROCESS + 1))
    else
        PROCESS_SLOTS=$SLOTS_PER_PROCESS
    fi
    
    PROCESS_START=$CURRENT_SLOT
    PROCESS_END=$((CURRENT_SLOT + PROCESS_SLOTS))
    
    LOG_FILE="$SCRIPT_DIR/logs/indexer-${i}.log"
    
    echo -e "${GREEN}  → indexer-${i}:${NC} slots ${PROCESS_START} to ${PROCESS_END} (${PROCESS_SLOTS} slots)"
    
    if [ "$USE_CARGO" = true ]; then
        (
            export SLOT_START=$PROCESS_START
            export SLOT_END=$PROCESS_END
            export THREADS=$THREADS_PER_PROCESS
            export CLICKHOUSE_URL=$CLICKHOUSE_URL
            cd "$SCRIPT_DIR" && cargo run --release > "$LOG_FILE" 2>&1
        ) &
    else
        (
            export SLOT_START=$PROCESS_START
            export SLOT_END=$PROCESS_END
            export THREADS=$THREADS_PER_PROCESS
            export CLICKHOUSE_URL=$CLICKHOUSE_URL
            $BINARY > "$LOG_FILE" 2>&1
        ) &
    fi
    
    PIDS+=($!)
    
    CURRENT_SLOT=$PROCESS_END
    
    sleep 0.5
done

echo ""
echo -e "${GREEN}✓ Started ${NUM_PROCESSES} indexer processes${NC}"
echo -e "${YELLOW}Logs:${NC} logs/indexer-*.log | ${YELLOW}Monitor:${NC} tail -f logs/indexer-*.log | ${YELLOW}Stop:${NC} pkill -f solixdb-indexer"
echo ""
echo -e "${YELLOW}Waiting for completion...${NC}"
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
    echo "  SELECT count() FROM transactions;"
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
