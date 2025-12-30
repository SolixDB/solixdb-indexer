//! ClickHouse Storage Module
//! 
//! Provides batched inserts with ZSTD compression for analytics-ready data storage.

use clickhouse::Client;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::{error, info};

#[derive(Debug, Clone, Serialize, Deserialize, clickhouse::Row)]
pub struct Transaction {
    pub signature: String,
    pub slot: u64,
    pub block_time: u64,
    pub program_id: String,
    #[serde(rename = "protocol_name")]
    pub protocol_name: String,
    #[serde(rename = "instruction_type")]
    pub instruction_type: String,
    pub success: u8,
    pub fee: u64,
    pub compute_units: u64,
    pub accounts_count: u16,
    pub date: String,
    pub hour: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, clickhouse::Row)]
pub struct TransactionPayload {
    pub signature: String,
    pub parsed_data: String,
    pub raw_data: String,
    pub log_messages: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, clickhouse::Row)]
pub struct FailedTransaction {
    pub signature: String,
    pub slot: u64,
    pub block_time: u64,
    pub program_id: String,
    pub protocol_name: String,
    pub raw_data: String,
    pub error_message: String,
}

pub struct ClickHouseStorage {
    client: Client,
    tx_buffer: Arc<Mutex<Vec<Transaction>>>,
    payload_buffer: Arc<Mutex<Vec<TransactionPayload>>>,
    failed_buffer: Arc<Mutex<Vec<FailedTransaction>>>,
    batch_size: usize,
}

impl ClickHouseStorage {
    /// Create a new ClickHouse storage instance and initialize tables
    pub async fn new(url: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let client = Client::default().with_url(url);
        let storage = Self {
            client: client.clone(),
            tx_buffer: Arc::new(Mutex::new(Vec::new())),
            payload_buffer: Arc::new(Mutex::new(Vec::new())),
            failed_buffer: Arc::new(Mutex::new(Vec::new())),
            batch_size: 1000,
        };
        storage.create_tables().await.map_err(|e| format!("{}", e))?;
        Ok(storage)
    }

    /// Create storage instance and clear existing tables (for testing)
    pub async fn new_with_clear(url: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let client = Client::default().with_url(url);
        let storage = Self {
            client: client.clone(),
            tx_buffer: Arc::new(Mutex::new(Vec::new())),
            payload_buffer: Arc::new(Mutex::new(Vec::new())),
            failed_buffer: Arc::new(Mutex::new(Vec::new())),
            batch_size: 1000,
        };
        storage.drop_all_tables().await.map_err(|e| format!("{}", e))?;
        storage.create_tables().await.map_err(|e| format!("{}", e))?;
        Ok(storage)
    }

    async fn create_tables(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // Table 1: transactions - optimized for analytics queries
        self.client
            .query(
                r#"
                CREATE TABLE IF NOT EXISTS transactions
                (
                    signature String,
                    slot UInt64,
                    block_time UInt64,
                    program_id String,
                    protocol_name LowCardinality(String),
                    instruction_type LowCardinality(String),
                    success UInt8,
                    fee UInt64,
                    compute_units UInt64,
                    accounts_count UInt16,
                    date String CODEC(ZSTD(3)),
                    hour UInt8
                )
                ENGINE = MergeTree()
                PARTITION BY toYYYYMM(toDateTime(block_time))
                ORDER BY (date, slot, signature)
                SETTINGS index_granularity = 8192
                "#
            )
            .execute()
            .await
            .map_err(|e| format!("{}", e))?;

        // Add bloom filter indexes
        self.client
            .query(
                r#"
                ALTER TABLE transactions
                ADD INDEX IF NOT EXISTS idx_protocol_name protocol_name TYPE bloom_filter(0.01) GRANULARITY 1
                "#
            )
            .execute()
            .await
            .ok(); // Ignore error if index already exists

        self.client
            .query(
                r#"
                ALTER TABLE transactions
                ADD INDEX IF NOT EXISTS idx_program_id program_id TYPE bloom_filter(0.01) GRANULARITY 1
                "#
            )
            .execute()
            .await
            .ok();

        self.client
            .query(
                r#"
                ALTER TABLE transactions
                ADD INDEX IF NOT EXISTS idx_signature signature TYPE bloom_filter(0.01) GRANULARITY 1
                "#
            )
            .execute()
            .await
            .ok();

        // Table 2: transaction_payloads - maximum compression storage
        self.client
            .query(
                r#"
                CREATE TABLE IF NOT EXISTS transaction_payloads
                (
                    signature String,
                    parsed_data String CODEC(ZSTD(22)),
                    raw_data String CODEC(ZSTD(22)),
                    log_messages String CODEC(ZSTD(22))
                )
                ENGINE = MergeTree()
                ORDER BY signature
                SETTINGS index_granularity = 8192
                "#
            )
            .execute()
            .await
            .map_err(|e| format!("{}", e))?;

        // Table 3: failed_transactions - for debugging
        self.client
            .query(
                r#"
                CREATE TABLE IF NOT EXISTS failed_transactions
                (
                    signature String,
                    slot UInt64,
                    block_time UInt64,
                    program_id String,
                    protocol_name String,
                    raw_data String CODEC(ZSTD(22)),
                    error_message String CODEC(ZSTD(22))
                )
                ENGINE = MergeTree()
                ORDER BY (slot, signature)
                SETTINGS index_granularity = 8192
                "#
            )
            .execute()
            .await
            .map_err(|e| format!("{}", e))?;

        info!("ClickHouse tables created successfully");
        Ok(())
    }

    async fn drop_all_tables(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.client
            .query("DROP TABLE IF EXISTS transactions")
            .execute()
            .await
            .map_err(|e| format!("{}", e))?;
        self.client
            .query("DROP TABLE IF EXISTS transaction_payloads")
            .execute()
            .await
            .map_err(|e| format!("{}", e))?;
        self.client
            .query("DROP TABLE IF EXISTS failed_transactions")
            .execute()
            .await
            .map_err(|e| format!("{}", e))?;
        info!("All ClickHouse tables dropped");
        Ok(())
    }

    /// Insert a transaction (batched)
    pub async fn insert_transaction(&self, tx: Transaction) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut buffer = self.tx_buffer.lock().await;
        buffer.push(tx);

        if buffer.len() >= self.batch_size {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer); // Release lock before async operation

            if let Err(e) = self.flush_transactions_batch(&batch).await {
                error!("Failed to flush transactions batch: {:?}", e);
                // Re-add to buffer on error
                let mut buffer = self.tx_buffer.lock().await;
                buffer.extend(batch);
            }
        }

        Ok(())
    }

    /// Insert a transaction payload (batched)
    pub async fn insert_payload(&self, payload: TransactionPayload) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut buffer = self.payload_buffer.lock().await;
        buffer.push(payload);

        if buffer.len() >= self.batch_size {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer);

            if let Err(e) = self.flush_payloads_batch(&batch).await {
                error!("Failed to flush payloads batch: {:?}", e);
                let mut buffer = self.payload_buffer.lock().await;
                buffer.extend(batch);
            }
        }

        Ok(())
    }

    /// Insert a failed transaction (batched)
    pub async fn insert_failed(&self, failed: FailedTransaction) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut buffer = self.failed_buffer.lock().await;
        buffer.push(failed);

        if buffer.len() >= self.batch_size {
            let batch = buffer.drain(..).collect::<Vec<_>>();
            drop(buffer);

            if let Err(e) = self.flush_failed_batch(&batch).await {
                error!("Failed to flush failed transactions batch: {:?}", e);
                let mut buffer = self.failed_buffer.lock().await;
                buffer.extend(batch);
            }
        }

        Ok(())
    }

    async fn flush_transactions_batch(&self, batch: &[Transaction]) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if batch.is_empty() {
            return Ok(());
        }
        let mut inserter = self.client.insert("transactions")
            .map_err(|e| format!("{}", e))?;
        for tx in batch {
            inserter.write(tx).await
                .map_err(|e| format!("{}", e))?;
        }
        inserter.end().await
            .map_err(|e| format!("{}", e))?;
        Ok(())
    }

    async fn flush_payloads_batch(&self, batch: &[TransactionPayload]) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if batch.is_empty() {
            return Ok(());
        }
        let mut inserter = self.client.insert("transaction_payloads")
            .map_err(|e| format!("{}", e))?;
        for payload in batch {
            inserter.write(payload).await
                .map_err(|e| format!("{}", e))?;
        }
        inserter.end().await
            .map_err(|e| format!("{}", e))?;
        Ok(())
    }

    async fn flush_failed_batch(&self, batch: &[FailedTransaction]) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if batch.is_empty() {
            return Ok(());
        }
        let mut inserter = self.client.insert("failed_transactions")
            .map_err(|e| format!("{}", e))?;
        for failed in batch {
            inserter.write(failed).await
                .map_err(|e| format!("{}", e))?;
        }
        inserter.end().await
            .map_err(|e| format!("{}", e))?;
        Ok(())
    }

    /// Flush all pending batches
    pub async fn flush_all(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // Flush transactions
        let tx_batch = {
            let mut buffer = self.tx_buffer.lock().await;
            buffer.drain(..).collect::<Vec<_>>()
        };
        if !tx_batch.is_empty() {
            self.flush_transactions_batch(&tx_batch).await
                .map_err(|e| format!("{}", e))?;
            info!("Flushed {} transactions", tx_batch.len());
        }

        // Flush payloads
        let payload_batch = {
            let mut buffer = self.payload_buffer.lock().await;
            buffer.drain(..).collect::<Vec<_>>()
        };
        if !payload_batch.is_empty() {
            self.flush_payloads_batch(&payload_batch).await
                .map_err(|e| format!("{}", e))?;
            info!("Flushed {} payloads", payload_batch.len());
        }

        // Flush failed
        let failed_batch = {
            let mut buffer = self.failed_buffer.lock().await;
            buffer.drain(..).collect::<Vec<_>>()
        };
        if !failed_batch.is_empty() {
            self.flush_failed_batch(&failed_batch).await
                .map_err(|e| format!("{}", e))?;
            info!("Flushed {} failed transactions", failed_batch.len());
        }

        Ok(())
    }

    /// Get storage statistics including compression ratios
    pub async fn get_storage_stats(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("\n=== ClickHouse Storage Stats ===");

        // Get compression stats for transactions table
        let stats: Vec<(String, u64, u64, f64)> = self
            .client
            .query(
                r#"
                SELECT 
                    table,
                    sum(rows) as total_rows,
                    sum(bytes_on_disk) as total_bytes,
                    sum(bytes_on_disk) / greatest(sum(rows), 1) as bytes_per_row
                FROM system.parts
                WHERE database = currentDatabase() 
                    AND table IN ('transactions', 'transaction_payloads', 'failed_transactions')
                    AND active = 1
                GROUP BY table
                ORDER BY table
                "#
            )
            .fetch_all()
            .await
            .map_err(|e| format!("{}", e))?;

        for (table, rows, bytes, bytes_per_row) in stats {
            let mb = bytes as f64 / (1024.0 * 1024.0);
            info!(
                "Table: {}, Rows: {}, Size: {:.2} MB, Bytes/Row: {:.2}",
                table, rows, mb, bytes_per_row
            );
        }

        // Get compression ratio
        let compression: Vec<(String, u64, u64, f64)> = self
            .client
            .query(
                r#"
                SELECT 
                    table,
                    sum(rows) as total_rows,
                    sum(bytes_on_disk) as compressed_bytes,
                    sum(data_uncompressed_bytes) as uncompressed_bytes
                FROM system.parts
                WHERE database = currentDatabase() 
                    AND table IN ('transactions', 'transaction_payloads', 'failed_transactions')
                    AND active = 1
                GROUP BY table
                HAVING uncompressed_bytes > 0
                ORDER BY table
                "#
            )
            .fetch_all()
            .await
            .map_err(|e| format!("{}", e))?;

        for (table, rows, compressed, uncompressed) in compression {
            let ratio = uncompressed as f64 / compressed as f64;
            info!(
                "Table: {}, Compression Ratio: {:.2}x ({} rows)",
                table, ratio, rows
            );
        }

        Ok(())
    }
}

