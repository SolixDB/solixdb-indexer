#!/bin/bash
# Generate docker-compose.yml with N collectors
# Usage: ./generate_collectors.sh [NUM_COLLECTORS] [SLOT_START] [SLOT_END]
# Example: ./generate_collectors.sh 32 377107390 383639270
#          ./generate_collectors.sh 32  # Uses default Nov 2025 slots

NUM_COLLECTORS=${1:-32}
SLOT_START=${2:-377107390}  # Nov 1, 2025 0:00 UTC (default)
SLOT_END=${3:-383639270}    # Dec 1, 2025 0:00 UTC (default)
TOTAL_SLOTS=$((SLOT_END - SLOT_START))
SLOTS_PER_COLLECTOR=$((TOTAL_SLOTS / NUM_COLLECTORS))
THREADS_PER_COLLECTOR=8

echo "Generating docker-compose.yml with $NUM_COLLECTORS collectors"
echo "Slot range: $SLOT_START to $SLOT_END"
echo "Total slots: $TOTAL_SLOTS"
echo "Slots per collector: ~$SLOTS_PER_COLLECTOR"
echo "Total threads: $((NUM_COLLECTORS * THREADS_PER_COLLECTOR))"

cat > docker-compose.yml << EOF
version: '3.8'

# Auto-generated: $NUM_COLLECTORS collectors
# Slot range: $SLOT_START to $SLOT_END (~$TOTAL_SLOTS slots)
# Each collector handles ~$SLOTS_PER_COLLECTOR slots

services:
EOF

for i in $(seq 1 $NUM_COLLECTORS); do
    COLLECTOR_START=$((SLOT_START + (i - 1) * SLOTS_PER_COLLECTOR))
    if [ $i -eq $NUM_COLLECTORS ]; then
        COLLECTOR_END=$SLOT_END
    else
        COLLECTOR_END=$((SLOT_START + i * SLOTS_PER_COLLECTOR))
    fi
    
    cat >> docker-compose.yml << EOF
  data-collector-$i:
    image: solixdb-collector:latest
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      - SLOT_START=$COLLECTOR_START
      - SLOT_END=$COLLECTOR_END
      - THREADS=$THREADS_PER_COLLECTOR
      - CLICKHOUSE_URL=http://clickhouse:8123
      - NETWORK=mainnet
      - CLEAR_DB_ON_START=false
      - CLEAR_DATA_AFTER=false
    depends_on:
      - clickhouse
    restart: unless-stopped

EOF
done

cat >> docker-compose.yml << EOF
  clickhouse:
    image: clickhouse/clickhouse-server:latest
    ports:
      - "8123:8123"
      - "9000:9000"
    volumes:
      - clickhouse_data:/var/lib/clickhouse
    environment:
      - CLICKHOUSE_DB=default
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    deploy:
      resources:
        limits:
          memory: 512G
        reservations:
          memory: 256G

volumes:
  clickhouse_data:
EOF

echo "Generated docker-compose.yml with $NUM_COLLECTORS collectors"

