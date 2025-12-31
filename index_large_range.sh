#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEFAULT_CHUNK_SIZE=10000
DEFAULT_NUM_PROCESSES=4
DEFAULT_THREADS=4

# Parse arguments
START_SLOT=${1:-}
END_SLOT=${2:-}
CHUNK_SIZE=${3:-$DEFAULT_CHUNK_SIZE}
NUM_PROCESSES=${4:-$DEFAULT_NUM_PROCESSES}
THREADS_PER_PROCESS=${5:-$DEFAULT_THREADS}
CLICKHOUSE_URL=${6:-""}

# Validate required arguments
if [ -z "$START_SLOT" ] || [ -z "$END_SLOT" ]; then
    echo -e "${RED}Error: START_SLOT and END_SLOT are required${NC}"
    echo "Usage: $0 <start_slot> <end_slot> [chunk_size] [num_processes] [threads_per_process] [clickhouse_url]"
    exit 1
fi

# Validate inputs
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

# Calculate total slots and chunks
TOTAL_SLOTS=$((END_SLOT - START_SLOT))
TOTAL_CHUNKS=$(( (TOTAL_SLOTS + CHUNK_SIZE - 1) / CHUNK_SIZE ))

# State file for resume capability
STATE_DIR="logs/large_range"
STATE_FILE="$STATE_DIR/.index_state"
PROGRESS_LOG="$STATE_DIR/progress.log"

# Create directories
mkdir -p "$STATE_DIR"
mkdir -p logs

# Load previous state if exists
CURRENT_CHUNK=1
CURRENT_START=$START_SLOT

if [ -f "$STATE_FILE" ]; then
    echo -e "${YELLOW}Found previous state file. Resuming...${NC}"
    source "$STATE_FILE"
    echo -e "${GREEN}Resuming from chunk $CURRENT_CHUNK/$TOTAL_CHUNKS (slot $CURRENT_START)${NC}"
    echo ""
else
    echo -e "${GREEN}Starting fresh indexing job${NC}"
    echo ""
fi

# Log function
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$PROGRESS_LOG"
}

# Save state function
save_state() {
    cat > "$STATE_FILE" <<EOF
CURRENT_CHUNK=$CURRENT_CHUNK
CURRENT_START=$CURRENT_START
EOF
}

# Print configuration
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Large Range Indexer${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Configuration:${NC}"
echo "  Total Slot Range: $START_SLOT to $END_SLOT"
echo "  Total Slots: $TOTAL_SLOTS"
echo "  Chunk Size: $CHUNK_SIZE slots"
echo "  Total Chunks: $TOTAL_CHUNKS"
echo "  Processes per Chunk: $NUM_PROCESSES"
echo "  Threads per Process: $THREADS_PER_PROCESS"
if [ -n "$CLICKHOUSE_URL" ]; then
    echo "  ClickHouse URL: $CLICKHOUSE_URL"
else
    echo "  ClickHouse URL: (will use config.toml or default)"
fi
echo "  State File: $STATE_FILE"
echo "  Progress Log: $PROGRESS_LOG"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

log "Starting large range indexing: $START_SLOT to $END_SLOT"
log "Chunk size: $CHUNK_SIZE, Processes: $NUM_PROCESSES, Threads: $THREADS_PER_PROCESS"

# Process chunks
CHUNK_START=$CURRENT_START
FIRST_CHUNK=$CURRENT_CHUNK

while [ $CHUNK_START -lt $END_SLOT ]; do
    CHUNK_END=$((CHUNK_START + CHUNK_SIZE))
    if [ $CHUNK_END -gt $END_SLOT ]; then
        CHUNK_END=$END_SLOT
    fi
    
    CHUNK_SLOTS=$((CHUNK_END - CHUNK_START))
    PERCENTAGE=$(( (CHUNK_START - START_SLOT) * 100 / TOTAL_SLOTS ))
    
    echo ""
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}Processing Chunk $CURRENT_CHUNK/$TOTAL_CHUNKS${NC}"
    echo -e "${YELLOW}  Slot Range: $CHUNK_START to $CHUNK_END ($CHUNK_SLOTS slots)${NC}"
    echo -e "${YELLOW}  Overall Progress: $PERCENTAGE% ($(($CHUNK_START - $START_SLOT))/$TOTAL_SLOTS slots)${NC}"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    
    log "Starting chunk $CURRENT_CHUNK/$TOTAL_CHUNKS: slots $CHUNK_START to $CHUNK_END"
    
    # Never clear DB automatically - user will do it manually
    CLEAR_DB="false"
    
    # Build command
    # run_parallel_indexers.sh: <start> <end> <processes> [threads] [clickhouse_url] [clear_db]
    CMD="./run_parallel_indexers.sh $CHUNK_START $CHUNK_END $NUM_PROCESSES $THREADS_PER_PROCESS"
    if [ -n "$CLICKHOUSE_URL" ]; then
        CMD="$CMD \"$CLICKHOUSE_URL\" $CLEAR_DB"
    else
        # If no ClickHouse URL, we can't pass clear_db as 6th arg without URL as 5th
        # So we'll rely on run_parallel_indexers.sh default behavior (first process clears)
        # But since we set CLEAR_DB=false, we need to pass it somehow
        # Actually, if CLICKHOUSE_URL is empty, we should just not pass clear_db
        # and let run_parallel_indexers.sh use its default (first=true, others=false)
        # But we want all to be false, so we need to pass empty string for URL
        CMD="$CMD \"\" $CLEAR_DB"
    fi
    
    # Run the chunk
    CHUNK_START_TIME=$(date +%s)
    if eval "$CMD"; then
        CHUNK_END_TIME=$(date +%s)
        CHUNK_DURATION=$((CHUNK_END_TIME - CHUNK_START_TIME))
        CHUNK_MINUTES=$((CHUNK_DURATION / 60))
        CHUNK_SECONDS=$((CHUNK_DURATION % 60))
        
        echo -e "${GREEN}✓ Chunk $CURRENT_CHUNK completed in ${CHUNK_MINUTES}m ${CHUNK_SECONDS}s${NC}"
        log "Chunk $CURRENT_CHUNK completed successfully in ${CHUNK_MINUTES}m ${CHUNK_SECONDS}s"
        
        # Update state for next chunk
        CURRENT_CHUNK=$((CURRENT_CHUNK + 1))
        CHUNK_START=$CHUNK_END
        save_state
        
        # Estimate remaining time
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
        log "State saved. You can resume by running this script again."
        echo ""
        echo -e "${YELLOW}Chunk failed. State has been saved.${NC}"
        echo -e "${YELLOW}To resume, simply run this script again with the same parameters.${NC}"
        exit $EXIT_CODE
    fi
done

# Completion
FINAL_TIME=$(date +%s)
if [ -f "$STATE_FILE" ]; then
    START_TIME=$(stat -f %B "$STATE_FILE" 2>/dev/null || stat -c %Y "$STATE_FILE" 2>/dev/null || echo $FINAL_TIME)
    TOTAL_DURATION=$((FINAL_TIME - START_TIME))
else
    TOTAL_DURATION=0
fi

TOTAL_HOURS=$((TOTAL_DURATION / 3600))
TOTAL_MINUTES=$(( (TOTAL_DURATION % 3600) / 60 ))

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ All chunks completed successfully!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Total slots indexed: $TOTAL_SLOTS${NC}"
echo -e "${YELLOW}Total chunks processed: $TOTAL_CHUNKS${NC}"
if [ $TOTAL_DURATION -gt 0 ]; then
    echo -e "${YELLOW}Total time: ${TOTAL_HOURS}h ${TOTAL_MINUTES}m${NC}"
fi
echo ""

log "SUCCESS: All chunks completed! Total slots: $TOTAL_SLOTS"

# Clean up state file on success
if [ -f "$STATE_FILE" ]; then
    rm "$STATE_FILE"
    log "State file cleaned up"
fi

echo -e "${GREEN}Check your ClickHouse database for the indexed data!${NC}"
echo -e "${YELLOW}Query example: SELECT count() FROM transactions;${NC}"
echo ""

exit 0

