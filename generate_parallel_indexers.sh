#!/bin/bash
# This file was AI generated
# Generate parallel indexer containers with auto-distributed slot ranges
# Usage: ./generate_parallel_indexers.sh <start_slot> <end_slot> <num_containers> [memory_per_container] [clickhouse_url]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
DEFAULT_START_SLOT=377107390
DEFAULT_END_SLOT=377107490
DEFAULT_NUM_CONTAINERS=4
DEFAULT_MEMORY="2G"

START_SLOT=${1:-$DEFAULT_START_SLOT}
END_SLOT=${2:-$DEFAULT_END_SLOT}
NUM_CONTAINERS=${3:-$DEFAULT_NUM_CONTAINERS}
MEMORY_PER_CONTAINER=${4:-$DEFAULT_MEMORY}
CLICKHOUSE_URL=${5:-${CLICKHOUSE_URL:-http://clickhouse:8123}}

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

TOTAL_SLOTS=$((END_SLOT - START_SLOT))
SLOTS_PER_CONTAINER=$((TOTAL_SLOTS / NUM_CONTAINERS))
REMAINDER=$((TOTAL_SLOTS % NUM_CONTAINERS))

echo -e "${GREEN}Generating docker-compose.parallel.yml${NC}"
echo "Range: $START_SLOT-$END_SLOT ($TOTAL_SLOTS slots, $NUM_CONTAINERS containers)"
echo "Memory: $MEMORY_PER_CONTAINER per container | ClickHouse: $CLICKHOUSE_URL"
echo ""

cat > docker-compose.parallel.yml <<EOF
version: '3.8'

services:
EOF

CURRENT_SLOT=$START_SLOT
for i in $(seq 1 $NUM_CONTAINERS); do
    if [ $i -le $REMAINDER ]; then
        CONTAINER_SLOTS=$((SLOTS_PER_CONTAINER + 1))
    else
        CONTAINER_SLOTS=$SLOTS_PER_CONTAINER
    fi
    
    CONTAINER_START=$CURRENT_SLOT
    CONTAINER_END=$((CURRENT_SLOT + CONTAINER_SLOTS))
    
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

cat >> docker-compose.parallel.yml <<EOF

networks:
  indexer-network:
    driver: bridge
  clickhouse-network:
    external: true
    name: clickhouse-network
EOF

echo ""
echo -e "${GREEN}✓ Generated docker-compose.parallel.yml${NC}"
echo -e "${YELLOW}Start:${NC} docker-compose -f docker-compose.parallel.yml up -d"
echo -e "${YELLOW}Logs:${NC} docker-compose -f docker-compose.parallel.yml logs -f"
echo -e "${YELLOW}Stop:${NC} docker-compose -f docker-compose.parallel.yml down"

