use crate::types::{FailedTransaction, ProtocolEvent, Transaction, TransactionPayload};
use clickhouse::Client;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::info;

pub struct ClickHouseStorage {
    pub(crate) client: Client,
    tx_buffer: Arc<Mutex<Vec<Transaction>>>,
    payload_buffer: Arc<Mutex<Vec<TransactionPayload>>>,
    event_buffer: Arc<Mutex<Vec<ProtocolEvent>>>,
    failed_buffer: Arc<Mutex<Vec<FailedTransaction>>>,
    batch_size: usize,
}

impl ClickHouseStorage {
    pub async fn new(url: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let client = Client::default().with_url(url);
        let storage = Self {
            client: client.clone(),
            tx_buffer: Arc::new(Mutex::new(Vec::new())),
            payload_buffer: Arc::new(Mutex::new(Vec::new())),
            event_buffer: Arc::new(Mutex::new(Vec::new())),
            failed_buffer: Arc::new(Mutex::new(Vec::new())),
            batch_size: 1000,
        };
        storage.create_tables().await?;
        Ok(storage)
    }

    pub async fn new_with_clear(url: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let client = Client::default().with_url(url);
        let storage = Self {
            client: client.clone(),
            tx_buffer: Arc::new(Mutex::new(Vec::new())),
            payload_buffer: Arc::new(Mutex::new(Vec::new())),
            event_buffer: Arc::new(Mutex::new(Vec::new())),
            failed_buffer: Arc::new(Mutex::new(Vec::new())),
            batch_size: 1000,
        };
        
        storage.drop_all_tables().await?;
        storage.create_tables().await?;
        
        Ok(storage)
    }

    async fn create_tables(&self) -> Result<(), Box<dyn std::error::Error>> {
        self.client
            .query(
                r#"
                CREATE TABLE IF NOT EXISTS transactions (
                    signature String CODEC(ZSTD(22)),
                    slot UInt64 CODEC(ZSTD(22)),
                    block_time UInt64 CODEC(ZSTD(22)),
                    program_id String CODEC(ZSTD(22)),
                    protocol_name LowCardinality(String) CODEC(ZSTD(22)),
                    instruction_type LowCardinality(String) CODEC(ZSTD(22)),
                    success UInt8 CODEC(ZSTD(22)),
                    fee UInt64 CODEC(ZSTD(22)),
                    compute_units UInt64 CODEC(ZSTD(22)),
                    accounts_count UInt16 CODEC(ZSTD(22)),
                    date String CODEC(ZSTD(22)),
                    hour UInt8 CODEC(ZSTD(22)),
                    day_of_week UInt8 CODEC(ZSTD(22)),
                    INDEX idx_signature signature TYPE bloom_filter GRANULARITY 1,
                    INDEX idx_program program_id TYPE bloom_filter GRANULARITY 1,
                    INDEX idx_protocol protocol_name TYPE bloom_filter GRANULARITY 1,
                    INDEX idx_date date TYPE bloom_filter GRANULARITY 1,
                    INDEX idx_slot slot TYPE minmax GRANULARITY 3
                )
                ENGINE = MergeTree()
                ORDER BY (date, slot, signature)
                PARTITION BY toYYYYMM(toDateTime(block_time))
                SETTINGS index_granularity = 8192
                "#,
            )
            .execute()
            .await?;

        self.client
            .query(
                r#"
                CREATE TABLE IF NOT EXISTS transaction_payloads (
                    signature String CODEC(ZSTD(22)),
                    parsed_data String CODEC(ZSTD(22)),
                    raw_data String CODEC(ZSTD(22)),
                    log_messages String CODEC(ZSTD(22))
                )
                ENGINE = MergeTree()
                ORDER BY (signature)
                SETTINGS index_granularity = 8192
                "#,
            )
            .execute()
            .await?;

        self.client
            .query(
                r#"
                CREATE TABLE IF NOT EXISTS protocol_events (
                    signature String CODEC(ZSTD(22)),
                    slot UInt64 CODEC(ZSTD(22)),
                    block_time UInt64 CODEC(ZSTD(22)),
                    protocol LowCardinality(String) CODEC(ZSTD(22)),
                    event_type LowCardinality(String) CODEC(ZSTD(22)),
                    event_data String CODEC(ZSTD(22)),
                    amount_sol UInt64 CODEC(ZSTD(22)),
                    amount_token UInt64 CODEC(ZSTD(22)),
                    price Float64 CODEC(ZSTD(22)),
                    user String CODEC(ZSTD(22)),
                    mint String CODEC(ZSTD(22)),
                    INDEX idx_protocol protocol TYPE bloom_filter GRANULARITY 1,
                    INDEX idx_event_type event_type TYPE bloom_filter GRANULARITY 1,
                    INDEX idx_user user TYPE bloom_filter GRANULARITY 1,
                    INDEX idx_mint mint TYPE bloom_filter GRANULARITY 1,
                    INDEX idx_slot slot TYPE minmax GRANULARITY 3
                )
                ENGINE = MergeTree()
                ORDER BY (protocol, slot, signature)
                PARTITION BY toYYYYMM(toDateTime(block_time))
                SETTINGS index_granularity = 8192
                "#,
            )
            .execute()
            .await?;

        self.client
            .query(
                r#"
                CREATE TABLE IF NOT EXISTS failed_transactions (
                    signature String CODEC(ZSTD(22)),
                    slot UInt64 CODEC(ZSTD(22)),
                    block_time UInt64 CODEC(ZSTD(22)),
                    program_id String CODEC(ZSTD(22)),
                    protocol_name LowCardinality(String) CODEC(ZSTD(22)),
                    raw_data String CODEC(ZSTD(22)),
                    log_messages String CODEC(ZSTD(22)),
                    error String CODEC(ZSTD(22)),
                    INDEX idx_signature signature TYPE bloom_filter GRANULARITY 1,
                    INDEX idx_program program_id TYPE bloom_filter GRANULARITY 1,
                    INDEX idx_slot slot TYPE minmax GRANULARITY 3
                )
                ENGINE = MergeTree()
                ORDER BY (slot, signature)
                PARTITION BY toYYYYMM(toDateTime(block_time))
                SETTINGS index_granularity = 8192
                "#,
            )
            .execute()
            .await?;

        info!("ClickHouse tables created");
        Ok(())
    }

    pub async fn insert_transaction(
        &self,
        tx: Transaction,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let mut buffer = self.tx_buffer.lock().await;
        buffer.push(tx);
        
        if buffer.len() >= self.batch_size {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer);
            
            let mut insert = self.client.insert::<Transaction>("transactions").await?;
            for item in &batch {
                insert.write(item).await?;
            }
            insert.end().await?;
        }
        
        Ok(())
    }

    pub async fn insert_payload(
        &self,
        payload: TransactionPayload,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let mut buffer = self.payload_buffer.lock().await;
        buffer.push(payload);
        
        if buffer.len() >= self.batch_size {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer);
            
            let mut insert = self
                .client
                .insert::<TransactionPayload>("transaction_payloads")
                .await?;
            for item in &batch {
                insert.write(item).await?;
            }
            insert.end().await?;
        }
        
        Ok(())
    }

    pub async fn insert_protocol_event(
        &self,
        event: ProtocolEvent,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let mut buffer = self.event_buffer.lock().await;
        buffer.push(event);
        
        if buffer.len() >= self.batch_size {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer);
            
            let mut insert = self
                .client
                .insert::<ProtocolEvent>("protocol_events")
                .await?;
            for item in &batch {
                insert.write(item).await?;
            }
            insert.end().await?;
        }
        
        Ok(())
    }

    pub async fn insert_failed_transaction(
        &self,
        failed: FailedTransaction,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let mut buffer = self.failed_buffer.lock().await;
        buffer.push(failed);
        
        if buffer.len() >= self.batch_size {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer);
            
            let mut insert = self
                .client
                .insert::<FailedTransaction>("failed_transactions")
                .await?;
            for item in &batch {
                insert.write(item).await?;
            }
            insert.end().await?;
        }
        
        Ok(())
    }

    pub async fn flush_all(&self) -> Result<(), Box<dyn std::error::Error>> {
        let mut buffer = self.tx_buffer.lock().await;
        if !buffer.is_empty() {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer);
            
            let mut insert = self.client.insert::<Transaction>("transactions").await?;
            for item in &batch {
                insert.write(item).await?;
            }
            insert.end().await?;
        }

        let mut buffer = self.payload_buffer.lock().await;
        if !buffer.is_empty() {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer);
            
            let mut insert = self
                .client
                .insert::<TransactionPayload>("transaction_payloads")
                .await?;
            for item in &batch {
                insert.write(item).await?;
            }
            insert.end().await?;
        }

        let mut buffer = self.event_buffer.lock().await;
        if !buffer.is_empty() {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer);
            
            let mut insert = self
                .client
                .insert::<ProtocolEvent>("protocol_events")
                .await?;
            for item in &batch {
                insert.write(item).await?;
            }
            insert.end().await?;
        }

        let mut buffer = self.failed_buffer.lock().await;
        if !buffer.is_empty() {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer);
            
            let mut insert = self
                .client
                .insert::<FailedTransaction>("failed_transactions")
                .await?;
            for item in &batch {
                insert.write(item).await?;
            }
            insert.end().await?;
        }

        Ok(())
    }

    pub async fn clear_all_data(&self) -> Result<(), Box<dyn std::error::Error>> {
        info!("Clearing all ClickHouse tables...");

        let tables = ["transactions", "transaction_payloads", "protocol_events", "failed_transactions"];
        for table in tables {
            self.client
                .query(format!("TRUNCATE TABLE IF EXISTS {}", table).as_str())
                .execute()
                .await?;
            info!("Cleared table: {}", table);
        }

        info!("All tables cleared successfully");
        Ok(())
    }

    pub async fn drop_all_tables(&self) -> Result<(), Box<dyn std::error::Error>> {
        info!("Dropping all ClickHouse tables...");

        let tables = ["transactions", "transaction_payloads", "protocol_events", "failed_transactions"];
        for table in tables {
            self.client
                .query(format!("DROP TABLE IF EXISTS {}", table).as_str())
                .execute()
                .await?;
            info!("Dropped table: {}", table);
        }

        info!("All tables dropped successfully");
        Ok(())
    }


    pub async fn get_storage_stats(&self) -> Result<(), Box<dyn std::error::Error>> {
        let query = r#"
            SELECT 
                table,
                formatReadableSize(sum(bytes)) as raw,
                formatReadableSize(sum(bytes_on_disk)) as compressed,
                round(sum(bytes) / sum(bytes_on_disk), 2) as ratio
            FROM system.parts
            WHERE active AND database = currentDatabase()
            GROUP BY table
            ORDER BY table
        "#;

        #[derive(Debug, clickhouse::Row, serde::Deserialize)]
        struct TableStats {
            table: String,
            raw: String,
            compressed: String,
            ratio: f64,
        }

        let stats = self.client.query(query).fetch_all::<TableStats>().await?;

        info!("=== ClickHouse Storage Statistics ===");
        for stat in stats {
            info!(
                "Table: {} | Raw: {} | Compressed: {} | Ratio: {}x",
                stat.table, stat.raw, stat.compressed, stat.ratio
            );
        }

        Ok(())
    }
}
