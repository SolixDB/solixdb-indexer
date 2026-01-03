#!/bin/bash
# This file was AI generated

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DEFAULT_CHUNK_SIZE=10000
DEFAULT_NUM_PROCESSES=4
DEFAULT_THREADS=4

START_SLOT=${1:-}
END_SLOT=${2:-}
CHUNK_SIZE=${3:-$DEFAULT_CHUNK_SIZE}
NUM_PROCESSES=${4:-$DEFAULT_NUM_PROCESSES}
THREADS_PER_PROCESS=${5:-$DEFAULT_THREADS}
CLICKHOUSE_URL=${6:-""}

if [ -z "$START_SLOT" ] || [ -z "$END_SLOT" ]; then
    echo -e "${RED}Error: START_SLOT and END_SLOT are required${NC}"
    echo "Usage: $0 <start_slot> <end_slot> [chunk_size] [num_processes] [threads_per_process] [clickhouse_url]"
    exit 1
fi

if ! [[ "$START_SLOT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: START_SLOT must be a number${NC}"
    exit 1
fi

if ! [[ "$END_SLOT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: END_SLOT must be a number${NC}"
    exit 1
fi

if ! [[ "$CHUNK_SIZE" =~ ^[0-9]+$ ]] || [ "$CHUNK_SIZE" -lt 100 ]; then
    echo -e "${RED}Error: CHUNK_SIZE must be at least 100${NC}"
    exit 1
fi

if ! [[ "$NUM_PROCESSES" =~ ^[0-9]+$ ]] || [ "$NUM_PROCESSES" -lt 1 ]; then
    echo -e "${RED}Error: NUM_PROCESSES must be at least 1${NC}"
    exit 1
fi

if [ "$START_SLOT" -ge "$END_SLOT" ]; then
    echo -e "${RED}Error: START_SLOT ($START_SLOT) must be less than END_SLOT ($END_SLOT)${NC}"
    exit 1
fi

TOTAL_SLOTS=$((END_SLOT - START_SLOT))
TOTAL_CHUNKS=$(( (TOTAL_SLOTS + CHUNK_SIZE - 1) / CHUNK_SIZE ))

PROGRESS_LOG="logs/large_range/progress.log"

mkdir -p logs/large_range
mkdir -p logs

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$PROGRESS_LOG"
}

echo -e "${GREEN}Large Range Indexer${NC}"
echo "Range: $START_SLOT-$END_SLOT ($TOTAL_SLOTS slots, $TOTAL_CHUNKS chunks)"
echo "Config: $NUM_PROCESSES processes × $THREADS_PER_PROCESS threads, chunk size: $CHUNK_SIZE"
echo ""

log "Starting large range indexing: $START_SLOT to $END_SLOT"
log "Chunk size: $CHUNK_SIZE, Processes: $NUM_PROCESSES, Threads: $THREADS_PER_PROCESS"

CHUNK_START=$START_SLOT
CURRENT_CHUNK=1

while [ $CHUNK_START -lt $END_SLOT ]; do
    CHUNK_END=$((CHUNK_START + CHUNK_SIZE))
    if [ $CHUNK_END -gt $END_SLOT ]; then
        CHUNK_END=$END_SLOT
    fi
    
    CHUNK_SLOTS=$((CHUNK_END - CHUNK_START))
    PERCENTAGE=$(( (CHUNK_START - START_SLOT) * 100 / TOTAL_SLOTS ))
    
    echo -e "${GREEN}Chunk $CURRENT_CHUNK/$TOTAL_CHUNKS:${NC} $CHUNK_START-$CHUNK_END ($PERCENTAGE%)"
    
    log "Starting chunk $CURRENT_CHUNK/$TOTAL_CHUNKS: slots $CHUNK_START to $CHUNK_END"
    
    CMD="$SCRIPT_DIR/run_parallel_indexers.sh $CHUNK_START $CHUNK_END $NUM_PROCESSES $THREADS_PER_PROCESS"
    if [ -n "$CLICKHOUSE_URL" ]; then
        CMD="$CMD \"$CLICKHOUSE_URL\""
    fi
    
    CHUNK_START_TIME=$(date +%s)
    if eval "$CMD"; then
        CHUNK_END_TIME=$(date +%s)
        CHUNK_DURATION=$((CHUNK_END_TIME - CHUNK_START_TIME))
        CHUNK_MINUTES=$((CHUNK_DURATION / 60))
        CHUNK_SECONDS=$((CHUNK_DURATION % 60))
        
        echo -e "${GREEN}✓ Chunk $CURRENT_CHUNK completed in ${CHUNK_MINUTES}m ${CHUNK_SECONDS}s${NC}"
        log "Chunk $CURRENT_CHUNK completed successfully in ${CHUNK_MINUTES}m ${CHUNK_SECONDS}s"
        
        CURRENT_CHUNK=$((CURRENT_CHUNK + 1))
        CHUNK_START=$CHUNK_END
        
        if [ $CURRENT_CHUNK -le $TOTAL_CHUNKS ]; then
            REMAINING_CHUNKS=$((TOTAL_CHUNKS - CURRENT_CHUNK + 1))
            ESTIMATED_SECONDS=$((REMAINING_CHUNKS * CHUNK_DURATION))
            ESTIMATED_HOURS=$((ESTIMATED_SECONDS / 3600))
            ESTIMATED_MINUTES=$(( (ESTIMATED_SECONDS % 3600) / 60 ))
            echo -e "${YELLOW}  Estimated time remaining: ~${ESTIMATED_HOURS}h ${ESTIMATED_MINUTES}m${NC}"
        fi
    else
        EXIT_CODE=$?
        echo -e "${RED}✗ Chunk $CURRENT_CHUNK failed with exit code $EXIT_CODE${NC}"
        log "ERROR: Chunk $CURRENT_CHUNK failed with exit code $EXIT_CODE"
        exit $EXIT_CODE
    fi
done

echo ""
echo -e "${GREEN}✓ All chunks completed!${NC} ($TOTAL_SLOTS slots, $TOTAL_CHUNKS chunks)"
log "SUCCESS: All chunks completed! Total slots: $TOTAL_SLOTS"
echo ""

exit 0
