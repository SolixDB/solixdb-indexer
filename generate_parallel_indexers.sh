#!/bin/bash

# Generate parallel indexer containers with auto-distributed slot ranges
# Usage: ./generate_parallel_indexers.sh <start_slot> <end_slot> <num_containers> [memory_per_container] [clickhouse_url]
# 
# Note: ClickHouse should be running separately. Set CLICKHOUSE_URL environment variable
# or pass it as 5th argument. Default: http://clickhouse:8123

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DEFAULT_START_SLOT=377107390
DEFAULT_END_SLOT=377107490
DEFAULT_NUM_CONTAINERS=4
DEFAULT_MEMORY="2G"

# Parse arguments
START_SLOT=${1:-$DEFAULT_START_SLOT}
END_SLOT=${2:-$DEFAULT_END_SLOT}
NUM_CONTAINERS=${3:-$DEFAULT_NUM_CONTAINERS}
MEMORY_PER_CONTAINER=${4:-$DEFAULT_MEMORY}
CLICKHOUSE_URL=${5:-${CLICKHOUSE_URL:-http://clickhouse:8123}}

# Validate inputs
if ! [[ "$START_SLOT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: START_SLOT must be a number${NC}"
    exit 1
fi

if ! [[ "$END_SLOT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: END_SLOT must be a number${NC}"
    exit 1
fi

if ! [[ "$NUM_CONTAINERS" =~ ^[0-9]+$ ]] || [ "$NUM_CONTAINERS" -lt 1 ] || [ "$NUM_CONTAINERS" -gt 100 ]; then
    echo -e "${RED}Error: NUM_CONTAINERS must be between 1 and 100${NC}"
    exit 1
fi

if [ "$START_SLOT" -ge "$END_SLOT" ]; then
    echo -e "${RED}Error: START_SLOT ($START_SLOT) must be less than END_SLOT ($END_SLOT)${NC}"
    exit 1
fi

# Calculate slot distribution
TOTAL_SLOTS=$((END_SLOT - START_SLOT))
SLOTS_PER_CONTAINER=$((TOTAL_SLOTS / NUM_CONTAINERS))
REMAINDER=$((TOTAL_SLOTS % NUM_CONTAINERS))

echo -e "${GREEN}Generating docker-compose.parallel.yml${NC}"
echo -e "${YELLOW}Configuration:${NC}"
echo "  Start Slot: $START_SLOT"
echo "  End Slot: $END_SLOT"
echo "  Total Slots: $TOTAL_SLOTS"
echo "  Number of Containers: $NUM_CONTAINERS"
echo "  Slots per Container: $SLOTS_PER_CONTAINER"
echo "  Remainder: $REMAINDER"
echo "  Memory per Container: $MEMORY_PER_CONTAINER"
echo "  ClickHouse URL: $CLICKHOUSE_URL"
echo ""
echo -e "${YELLOW}Note:${NC} ClickHouse should be running separately. Make sure it's accessible at: $CLICKHOUSE_URL"
echo ""

# Generate docker-compose.parallel.yml (indexers only)
cat > docker-compose.parallel.yml <<EOF
version: '3.8'

services:
EOF

# Generate indexer services
CURRENT_SLOT=$START_SLOT
for i in $(seq 1 $NUM_CONTAINERS); do
    # Calculate slot range for this container
    if [ $i -le $REMAINDER ]; then
        # First REMAINDER containers get one extra slot
        CONTAINER_SLOTS=$((SLOTS_PER_CONTAINER + 1))
    else
        CONTAINER_SLOTS=$SLOTS_PER_CONTAINER
    fi
    
    CONTAINER_START=$CURRENT_SLOT
    CONTAINER_END=$((CURRENT_SLOT + CONTAINER_SLOTS))
    
    # First container clears DB, others don't
    if [ $i -eq 1 ]; then
        CLEAR_DB="true"
    else
        CLEAR_DB="false"
    fi
    
    cat >> docker-compose.parallel.yml <<EOF
  indexer-${i}:
    build:
      context: .
      dockerfile: Dockerfile
    image: solixdb-indexer:latest
    container_name: indexer-${i}
    environment:
      - SLOT_START=${CONTAINER_START}
      - SLOT_END=${CONTAINER_END}
      - THREADS=4
      - CLICKHOUSE_URL=${CLICKHOUSE_URL}
      - CLEAR_DB_ON_START=${CLEAR_DB}
    restart: "no"
    networks:
      - indexer-network
      - clickhouse-network
    deploy:
      resources:
        limits:
          memory: ${MEMORY_PER_CONTAINER}
        reservations:
          memory: ${MEMORY_PER_CONTAINER}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

EOF
    
    echo -e "${GREEN}  indexer-${i}:${NC} slots ${CONTAINER_START} to ${CONTAINER_END} (${CONTAINER_SLOTS} slots) - CLEAR_DB_ON_START=${CLEAR_DB}"
    
    CURRENT_SLOT=$CONTAINER_END
done

# Add networks - connect to ClickHouse network
cat >> docker-compose.parallel.yml <<EOF

networks:
  indexer-network:
    driver: bridge
  clickhouse-network:
    external: true
    name: data_clickhouse-network
EOF

echo ""
echo -e "${GREEN}✓ Generated docker-compose.parallel.yml${NC}"
echo ""
echo -e "${YELLOW}Important:${NC} Make sure ClickHouse is running before starting indexers!"
echo ""
echo -e "${YELLOW}To start ClickHouse (if not already running):${NC}"
echo "  docker-compose -f docker-compose.clickhouse.yml up -d"
echo ""
echo -e "${YELLOW}To start all indexers:${NC}"
echo "  docker-compose -f docker-compose.parallel.yml up -d"
echo ""
echo -e "${YELLOW}To view logs:${NC}"
echo "  docker-compose -f docker-compose.parallel.yml logs -f"
echo ""
echo -e "${YELLOW}To stop all indexers:${NC}"
echo "  docker-compose -f docker-compose.parallel.yml down"

