mod helpers;
mod multi_parser;
mod storage;

use futures_util::FutureExt;
use helpers::print_summary;
use jetstreamer_firehose::firehose::*;
use multi_parser::build_parser_map;
use std::collections::HashMap;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::{Instant, SystemTime};
use storage::ClickHouseStorage;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_target(false)
        .with_thread_ids(false)
        .with_level(true)
        .init();

    let slot_start = std::env::var("SLOT_START")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(383639270);
    
    let slot_end = std::env::var("SLOT_END")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(383639271);

    if slot_start >= slot_end {
        return Err(format!(
            "Invalid slot range: SLOT_START ({}) must be less than SLOT_END ({})",
            slot_start, slot_end
        ).into());
    }

    let threads = std::env::var("THREADS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1);

    if threads == 0 {
        return Err("THREADS must be greater than 0".into());
    }

    unsafe {
        std::env::set_var("JETSTREAMER_NETWORK", "mainnet");
        std::env::set_var("JETSTREAMER_COMPACT_INDEX_BASE_URL", "https://files.old-faithful.net");
        std::env::set_var("JETSTREAMER_NETWORK_CAPACITY_MB", "100000");
    }

    // Initialize ClickHouse storage
    let clickhouse_url = std::env::var("CLICKHOUSE_URL")
        .unwrap_or_else(|_| "http://localhost:8123".to_string());
    
    let clear_db_on_start = std::env::var("CLEAR_DB_ON_START")
        .ok()
        .map(|s| s == "true")
        .unwrap_or(false);

    let storage = if clear_db_on_start {
        tracing::info!("Clearing database and recreating tables...");
        Arc::new(ClickHouseStorage::new_with_clear(&clickhouse_url).await
            .map_err(|e| format!("{}", e))?)
    } else {
        Arc::new(ClickHouseStorage::new(&clickhouse_url).await
            .map_err(|e| format!("{}", e))?)
    };

    // Build parser map
    let parser_map = build_parser_map();
    
    // Metrics per program - dynamically create based on parser map
    let mut metrics: HashMap<String, (Arc<AtomicU64>, Arc<AtomicU64>)> = HashMap::new();
    for (_, parser_name) in &parser_map {
        metrics.insert(
            parser_name.to_string(),
            (Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0))),
        );
    }

    let transaction_handler = {
        let parser_map = parser_map.clone();
        let metrics = metrics.clone();
        let storage = Arc::clone(&storage);
        
        move |_thread_id: usize, tx: TransactionData| {
            let parser_map = parser_map.clone();
            let metrics = metrics.clone();
            let storage = Arc::clone(&storage);
            
            async move {
                helpers::process_transaction(tx, &parser_map, &metrics, &storage).await
            }
            .boxed()
        }
    };

    let block_handler = move |_thread_id: usize, _block: BlockData| {
        async move { Ok::<(), Box<dyn std::error::Error + Send + Sync>>(()) }.boxed()
    };

    let entry_handler = move |_thread_id: usize, _entry: EntryData| {
        async move { Ok::<(), Box<dyn std::error::Error + Send + Sync>>(()) }.boxed()
    };

    let rewards_handler = move |_thread_id: usize, _rewards: RewardsData| {
        async move { Ok::<(), Box<dyn std::error::Error + Send + Sync>>(()) }.boxed()
    };

    let error_handler = move |_thread_id: usize, error_ctx: FirehoseErrorContext| {
        async move {
            eprintln!("Firehose error at slot {}: {}", error_ctx.slot, error_ctx.error_message);
            Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
        }
        .boxed()
    };

    let stats_handler = move |_thread_id: usize, _stats: Stats| {
        async move { Ok::<(), Box<dyn std::error::Error + Send + Sync>>(()) }.boxed()
    };

    let start_time = Instant::now();
    let start_timestamp = std::time::SystemTime::now();
    
    match firehose(
        threads as u64,
        slot_start..slot_end,
        Some(block_handler),
        Some(transaction_handler),
        Some(entry_handler),
        Some(rewards_handler),
        Some(error_handler),
        Some(StatsTracking {
            on_stats: stats_handler,
            tracking_interval_slots: 1000,
        }),
        None,
    )
    .await
    {
        Ok(_) => {
            let end_time = Instant::now();
            let end_timestamp = SystemTime::now();
            
            // Flush all pending batches
            tracing::info!("Flushing all pending batches...");
            if let Err(e) = storage.flush_all().await {
                tracing::error!("Failed to flush batches: {:?}", e);
            }

            print_summary(
                start_time,
                start_timestamp,
                end_time,
                end_timestamp,
                slot_start,
                slot_end,
                &metrics,
                threads,
            );

            // Print storage stats
            if let Err(e) = storage.get_storage_stats().await {
                tracing::error!("Failed to get storage stats: {:?}", e);
            }

            Ok(())
        }
        Err((e, slot)) => Err(format!("Error at slot {}: {:?}", slot, e).into()),
    }
}
