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
}

// Removed TransactionPayload - was taking 1.32 GiB with no compression benefit
// Debug strings aren't queryable and storage is limited (1-2TB)

#[derive(Debug, Clone, Serialize, Deserialize, clickhouse::Row)]
pub struct FailedTransaction {
    pub signature: String,
    pub slot: u64,
    pub block_time: u64,
    pub program_id: String,
    pub protocol_name: String,
    pub raw_data: String,
    pub error_message: String,
    pub log_messages: String,
}

pub struct ClickHouseStorage {
    client: Client,
    tx_buffer: Arc<Mutex<Vec<Transaction>>>,
    failed_buffer: Arc<Mutex<Vec<FailedTransaction>>>,
    batch_size: usize,
}

impl ClickHouseStorage {
    /// Create a new ClickHouse storage instance and initialize tables
    /// 
    /// URL format supports authentication:
    /// - `http://host:port` (no auth)
    /// - `http://username:password@host:port` (with auth)
    /// - `https://username:password@host:port` (with TLS)
    pub async fn new(url: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let client = Client::default().with_url(url);
        let batch_size = 50000;
        let storage = Self {
            client: client.clone(),
            tx_buffer: Arc::new(Mutex::new(Vec::with_capacity(batch_size))),
            failed_buffer: Arc::new(Mutex::new(Vec::with_capacity(batch_size))),
            batch_size,
        };
        
        // Health check: verify connection before proceeding
        storage.health_check().await
            .map_err(|e| format!("ClickHouse health check failed: {}. Please verify CLICKHOUSE_URL and credentials.", e))?;
        
        storage.create_tables().await.map_err(|e| format!("{}", e))?;
        Ok(storage)
    }

    /// Create storage instance and clear existing tables (for testing)
    pub async fn new_with_clear(url: &str) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let client = Client::default().with_url(url);
        let batch_size = 50000;
        let storage = Self {
            client: client.clone(),
            tx_buffer: Arc::new(Mutex::new(Vec::with_capacity(batch_size))),
            failed_buffer: Arc::new(Mutex::new(Vec::with_capacity(batch_size))),
            batch_size,
        };
        
        // Health check: verify connection before proceeding
        storage.health_check().await
            .map_err(|e| format!("ClickHouse health check failed: {}. Please verify CLICKHOUSE_URL and credentials.", e))?;
        
        storage.drop_all_tables().await.map_err(|e| format!("{}", e))?;
        storage.create_tables().await.map_err(|e| format!("{}", e))?;
        Ok(storage)
    }

    /// Health check: verify ClickHouse connection is working
    async fn health_check(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // Simple ping query to verify connection and authentication
        self.client
            .query("SELECT 1")
            .fetch_one::<u8>()
            .await
            .map_err(|e| format!("Connection test failed: {}", e))?;
        info!("ClickHouse connection verified successfully");
        Ok(())
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
                    program_id LowCardinality(String),
                    protocol_name LowCardinality(String),
                    instruction_type LowCardinality(String),
                    success UInt8,
                    fee UInt64,
                    compute_units UInt64,
                    accounts_count UInt16,
                    date Date MATERIALIZED toDate(block_time),
                    hour UInt8 MATERIALIZED toHour(toDateTime(block_time))
                )
                ENGINE = MergeTree()
                PARTITION BY toYYYYMM(date)
                ORDER BY (date, slot, signature)
                SETTINGS 
                    index_granularity = 8192,
                    async_insert = 1,
                    wait_for_async_insert = 1,
                    async_insert_busy_timeout_ms = 300000
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

        // Table 2: failed_transactions - for debugging
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
                    error_message String CODEC(ZSTD(22)),
                    log_messages String CODEC(ZSTD(22))
                )
                ENGINE = MergeTree()
                ORDER BY (slot, signature)
                SETTINGS 
                    index_granularity = 8192,
                    async_insert = 1,
                    wait_for_async_insert = 1,
                    async_insert_busy_timeout_ms = 300000
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
        
        // Retry logic for production resilience
        let max_retries = 3;
        let mut last_error = None;
        
        for attempt in 1..=max_retries {
            match self.try_insert_transactions(batch).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    last_error = Some(e);
                    if attempt < max_retries {
                        let delay_ms = 1000 * attempt; // Exponential backoff: 1s, 2s, 3s
                        error!("Failed to insert transactions batch (attempt {}/{}), retrying in {}ms...", 
                            attempt, max_retries, delay_ms);
                        tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;
                    }
                }
            }
        }
        
        Err(format!("Failed to insert transactions after {} retries: {:?}", 
            max_retries, last_error).into())
    }
    
    async fn try_insert_transactions(&self, batch: &[Transaction]) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
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

    async fn flush_failed_batch(&self, batch: &[FailedTransaction]) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if batch.is_empty() {
            return Ok(());
        }
        
        // Retry logic for production resilience
        let max_retries = 3;
        let mut last_error = None;
        
        for attempt in 1..=max_retries {
            match self.try_insert_failed(batch).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    last_error = Some(e);
                    if attempt < max_retries {
                        let delay_ms = 1000 * attempt;
                        error!("Failed to insert failed transactions batch (attempt {}/{}), retrying in {}ms...", 
                            attempt, max_retries, delay_ms);
                        tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;
                    }
                }
            }
        }
        
        Err(format!("Failed to insert failed transactions after {} retries: {:?}", 
            max_retries, last_error).into())
    }
    
    async fn try_insert_failed(&self, batch: &[FailedTransaction]) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
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
    /// This ensures all buffered data is written to ClickHouse and immediately queryable
    pub async fn flush_all(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        info!("Flushing all pending batches to ensure data is queryable...");
        
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

        // Force sync async inserts to ensure data is immediately queryable
        // This is important for REST/GraphQL APIs and analytics dashboards
        self.client
            .query("SYSTEM FLUSH ASYNC INSERT QUEUE")
            .execute()
            .await
            .ok(); // Ignore error if async inserts not enabled

        info!("All batches flushed. Data is now queryable via REST/GraphQL APIs.");
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
                    AND table IN ('transactions', 'failed_transactions')
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
                    AND table IN ('transactions', 'failed_transactions')
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

