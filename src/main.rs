mod config;
mod helpers;
mod multi_parser;
mod storage;

use config::Config;
use futures_util::FutureExt;
use helpers::print_summary;
use jetstreamer_firehose::firehose::*;
use multi_parser::build_parser_map;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Instant, SystemTime};
use storage::ClickHouseStorage;
use tokio::signal;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_target(false)
        .with_thread_ids(false)
        .with_level(true)
        .init();

    // Load configuration (config file + env vars)
    let config = Config::load()?;
    
    // Log loaded configuration
    tracing::info!("Loaded configuration:");
    tracing::info!("  Slots: {} to {}", config.slots.start, config.slots.end);
    tracing::info!("  ClickHouse URL: {}", config.clickhouse.url);
    tracing::info!("  Clear on start: {}", config.clickhouse.clear_on_start);
    tracing::info!("  Threads: {}", config.processing.threads);
    
    let slot_start = config.slots.start;
    let slot_end = config.slots.end;
    let threads = config.processing.threads;

    unsafe {
        std::env::set_var("JETSTREAMER_NETWORK", "mainnet");
        std::env::set_var("JETSTREAMER_COMPACT_INDEX_BASE_URL", "https://files.old-faithful.net");
        std::env::set_var("JETSTREAMER_NETWORK_CAPACITY_MB", "100000");
    }

    // Initialize ClickHouse storage
    let storage = if config.clickhouse.clear_on_start {
        tracing::info!("Clearing database and recreating tables...");
        Arc::new(ClickHouseStorage::new_with_clear(&config.clickhouse.url).await
            .map_err(|e| format!("{}", e))?)
    } else {
        Arc::new(ClickHouseStorage::new(&config.clickhouse.url).await
            .map_err(|e| format!("{}", e))?)
    };

    // Graceful shutdown signal handler
    let shutdown_flag = Arc::new(AtomicBool::new(false));
    let shutdown_flag_clone = Arc::clone(&shutdown_flag);
    let storage_clone = Arc::clone(&storage);
    
    tokio::spawn(async move {
        let mut sigterm = signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("Failed to register SIGTERM handler");
        let mut sigint = signal::unix::signal(signal::unix::SignalKind::interrupt())
            .expect("Failed to register SIGINT handler");
        
        tokio::select! {
            _ = sigterm.recv() => {
                tracing::info!("Received SIGTERM, initiating graceful shutdown...");
            }
            _ = sigint.recv() => {
                tracing::info!("Received SIGINT, initiating graceful shutdown...");
            }
        }
        
        shutdown_flag_clone.store(true, Ordering::Relaxed);
        
        // Flush all pending data
        tracing::info!("Flushing all pending batches before shutdown...");
        if let Err(e) = storage_clone.flush_all().await {
            tracing::error!("Failed to flush batches on shutdown: {:?}", e);
        }
        tracing::info!("Graceful shutdown complete");
    });

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
    
    let firehose_result = firehose(
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
    .await;
    
    match firehose_result {
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
        Err((e, slot)) => {
            // Flush pending batches even on error
            tracing::warn!("Error at slot {}: {:?}", slot, e);
            tracing::info!("Flushing pending batches before exit...");
            if let Err(flush_err) = storage.flush_all().await {
                tracing::error!("Failed to flush batches on error: {:?}", flush_err);
            }
            Err(format!("Error at slot {}: {:?}", slot, e).into())
        }
    }
}
