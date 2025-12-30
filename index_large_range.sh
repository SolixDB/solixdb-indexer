#!/bin/bash

# Automated large-range indexer with chunking and resume capability
# Processes 6.5M slots in manageable chunks, can resume if interrupted
#
# Usage: ./index_large_range.sh [clickhouse_url] [threads_per_process] [chunk_size] [processes_per_chunk]
#
# Example: ./index_large_range.sh http://localhost:8123 4 500000 20

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
START_SLOT=377107390
END_SLOT=383639270
CLICKHOUSE_URL=${1:-"http://localhost:8123"}
THREADS_PER_PROCESS=${2:-4}
CHUNK_SIZE=${3:-500000}  # 500k slots per chunk (safe size)
PROCESSES_PER_CHUNK=${4:-20}  # 20 parallel processes per chunk

# State tracking
STATE_FILE=".index_state"
LOG_DIR="logs/large_range"
PROGRESS_LOG="$LOG_DIR/progress.log"

# Create log directory
mkdir -p "$LOG_DIR"

# Load state if exists
if [ -f "$STATE_FILE" ]; then
    CURRENT_CHUNK_START=$(cat "$STATE_FILE")
    echo -e "${YELLOW}Resuming from saved state: chunk starting at $CURRENT_CHUNK_START${NC}"
else
    CURRENT_CHUNK_START=$START_SLOT
    echo "$CURRENT_CHUNK_START" > "$STATE_FILE"
fi

# Calculate total chunks
TOTAL_SLOTS=$((END_SLOT - START_SLOT))
TOTAL_CHUNKS=$(( (TOTAL_SLOTS + CHUNK_SIZE - 1) / CHUNK_SIZE ))
REMAINING_SLOTS=$((END_SLOT - CURRENT_CHUNK_START))
REMAINING_CHUNKS=$(( (REMAINING_SLOTS + CHUNK_SIZE - 1) / CHUNK_SIZE ))

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Large Range Indexer${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Total Range:     $START_SLOT to $END_SLOT ($TOTAL_SLOTS slots)"
echo -e "Chunk Size:      $CHUNK_SIZE slots"
echo -e "Processes/Chunk: $PROCESSES_PER_CHUNK"
echo -e "Threads/Process: $THREADS_PER_PROCESS"
echo -e "ClickHouse URL:  $CLICKHOUSE_URL"
echo -e "Starting From:   $CURRENT_CHUNK_START"
echo -e "Remaining:       $REMAINING_CHUNKS chunks ($REMAINING_SLOTS slots)"
echo -e "${BLUE}========================================${NC}"
echo ""

# Log start
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting large range indexer" >> "$PROGRESS_LOG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Range: $START_SLOT to $END_SLOT" >> "$PROGRESS_LOG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Resuming from: $CURRENT_CHUNK_START" >> "$PROGRESS_LOG"

CHUNK_NUM=1
CURRENT_START=$CURRENT_CHUNK_START

while [ $CURRENT_START -lt $END_SLOT ]; do
    # Calculate chunk end
    CHUNK_END=$((CURRENT_START + CHUNK_SIZE))
    if [ $CHUNK_END -gt $END_SLOT ]; then
        CHUNK_END=$END_SLOT
    fi
    
    CHUNK_SLOTS=$((CHUNK_END - CURRENT_START))
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Processing Chunk $CHUNK_NUM/$REMAINING_CHUNKS${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Range: $CURRENT_START to $CHUNK_END ($CHUNK_SLOTS slots)"
    echo -e "Time:  $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Log chunk start
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting chunk $CHUNK_NUM: $CURRENT_START to $CHUNK_END" >> "$PROGRESS_LOG"
    
    # Determine if we should clear DB (only first chunk)
    if [ $CURRENT_START -eq $START_SLOT ]; then
        CLEAR_DB="true"
    else
        CLEAR_DB="false"
    fi
    
    # Run the chunk
    CHUNK_START_TIME=$(date +%s)
    
    if ./run_parallel_indexers.sh "$CURRENT_START" "$CHUNK_END" "$PROCESSES_PER_CHUNK" "$THREADS_PER_PROCESS" "$CLICKHOUSE_URL" "$CLEAR_DB" >> "$LOG_DIR/chunk_${CHUNK_NUM}.log" 2>&1; then
        CHUNK_END_TIME=$(date +%s)
        CHUNK_DURATION=$((CHUNK_END_TIME - CHUNK_START_TIME))
        
        echo -e "${GREEN}✓ Chunk $CHUNK_NUM completed successfully${NC}"
        echo -e "  Duration: ${CHUNK_DURATION}s (~$((CHUNK_DURATION / 60)) minutes)"
        echo ""
        
        # Log success
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Chunk $CHUNK_NUM completed in ${CHUNK_DURATION}s" >> "$PROGRESS_LOG"
        
        # Update state
        CURRENT_START=$CHUNK_END
        echo "$CURRENT_START" > "$STATE_FILE"
        
        # Calculate progress
        PROCESSED_SLOTS=$((CURRENT_START - START_SLOT))
        PROGRESS_PCT=$((PROCESSED_SLOTS * 100 / TOTAL_SLOTS))
        echo -e "${BLUE}Overall Progress: $PROGRESS_PCT% ($PROCESSED_SLOTS / $TOTAL_SLOTS slots)${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Progress: $PROGRESS_PCT% ($PROCESSED_SLOTS / $TOTAL_SLOTS slots)" >> "$PROGRESS_LOG"
        
        CHUNK_NUM=$((CHUNK_NUM + 1))
        
        # Small delay between chunks to avoid overwhelming the system
        sleep 5
    else
        CHUNK_END_TIME=$(date +%s)
        CHUNK_DURATION=$((CHUNK_END_TIME - CHUNK_START_TIME))
        
        echo -e "${RED}✗ Chunk $CHUNK_NUM failed after ${CHUNK_DURATION}s${NC}"
        echo -e "${YELLOW}Check logs: $LOG_DIR/chunk_${CHUNK_NUM}.log${NC}"
        echo ""
        
        # Log failure
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Chunk $CHUNK_NUM failed after ${CHUNK_DURATION}s" >> "$PROGRESS_LOG"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] State saved at: $CURRENT_START" >> "$PROGRESS_LOG"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] To resume, run this script again" >> "$PROGRESS_LOG"
        
        echo -e "${YELLOW}Script will exit. To resume, run:${NC}"
        echo -e "${YELLOW}  ./index_large_range.sh $CLICKHOUSE_URL $THREADS_PER_PROCESS $CHUNK_SIZE $PROCESSES_PER_CHUNK${NC}"
        echo ""
        echo -e "${YELLOW}Or check the error and fix it, then resume.${NC}"
        
        exit 1
    fi
done

# All done!
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}🎉 All chunks completed successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Total Range: $START_SLOT to $END_SLOT"
echo -e "Total Chunks: $CHUNK_NUM"
echo -e "Completed: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Log completion
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ All chunks completed successfully!" >> "$PROGRESS_LOG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Total chunks: $CHUNK_NUM" >> "$PROGRESS_LOG"

# Clean up state file
rm -f "$STATE_FILE"

echo -e "${BLUE}Check progress log: $PROGRESS_LOG${NC}"
echo -e "${BLUE}Check individual chunk logs: $LOG_DIR/chunk_*.log${NC}"

