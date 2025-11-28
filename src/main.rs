use futures_util::FutureExt;
use jetstreamer_firehose::firehose::{
    BlockData, EntryData, FirehoseErrorContext, RewardsData, Stats, StatsTracking, TransactionData,
    firehose,
};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
use std::time::Instant;
use tracing::{error, info};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize tracing
    tracing_subscriber::fmt()
        .with_target(false)
        .with_thread_ids(false)
        .with_level(true)
        .init();

    info!("Starting Old Faithful transaction logger");

    // Configuration
    let slot_start = 325000000;
    let slot_end = 325000001;
    let threads = 1;
    let network = "mainnet";
    let compact_index_base_url = "https://files.old-faithful.net";
    let network_capacity_mb = 100_000;

    info!(
        slot_start = slot_start,
        slot_end = slot_end,
        threads = threads,
        network = network,
        "Configuration loaded"
    );

    // Set environment variables for jetstreamer
    unsafe {
        std::env::set_var("JETSTREAMER_NETWORK", network);
        std::env::set_var("JETSTREAMER_COMPACT_INDEX_BASE_URL", compact_index_base_url);
        std::env::set_var(
            "JETSTREAMER_NETWORK_CAPACITY_MB",
            network_capacity_mb.to_string(),
        );
    }

    let transaction_count = Arc::new(AtomicU64::new(0));
    let block_count = Arc::new(AtomicU64::new(0));

    info!("Starting data fetch from Old Faithful...");
    let start_time = Instant::now();

    // Block handler
    let blk_count = block_count.clone();
    let on_block = move |_thread_id: usize, block: BlockData| {
        let count_clone = blk_count.clone();
        async move {
            match block {
                BlockData::Block {
                    slot,
                    blockhash,
                    executed_transaction_count,
                    ..
                } => {
                    let count = count_clone.fetch_add(1, Ordering::Relaxed);
                    info!(
                        count = count,
                        slot = slot,
                        blockhash = %blockhash,
                        tx_count = executed_transaction_count,
                        "Block"
                    );
                }
                BlockData::PossibleLeaderSkipped { slot } => {
                    info!(slot = slot, "Skipped slot");
                }
            }
            Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
        }
        .boxed()
    };

    // Transaction handler
    let tx_count = transaction_count.clone();
    let on_tx = move |_thread_id: usize, tx: TransactionData| {
        let count_clone = tx_count.clone();
        async move {
            let count = count_clone.fetch_add(1, Ordering::Relaxed);

            info!(
                count = count,
                signature = %tx.signature,
                slot = tx.slot,
                index = tx.transaction_slot_index,
                is_vote = tx.is_vote,
                "Transaction"
            );

            // Progress update every 100 transactions
            if count > 0 && count % 100 == 0 {
                info!(count, "Progress: {} transactions processed", count);
            }

            Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
        }
        .boxed()
    };

    // Entry handler
    let on_entry = move |_thread_id: usize, entry: EntryData| {
        async move {
            info!(
                slot = entry.slot,
                index = entry.entry_index,
                num_hashes = entry.num_hashes,
                hash = %entry.hash,
                "Entry"
            );
            Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
        }
        .boxed()
    };

    // Rewards handler
    let on_rewards = move |_thread_id: usize, rewards: RewardsData| {
        async move {
            info!(
                slot = rewards.slot,
                num_rewards = rewards.rewards.len(),
                "Rewards"
            );
            Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
        }
        .boxed()
    };

    // Stats tracking handler
    let on_stats = move |_thread_id: usize, stats: Stats| {
        async move {
            info!(
                slots_processed = stats.slots_processed,
                blocks_processed = stats.blocks_processed,
                transactions_processed = stats.transactions_processed,
                "Stats update"
            );
            Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
        }
        .boxed()
    };

    // Error handler
    let on_error = move |_thread_id: usize, error_ctx: FirehoseErrorContext| {
        async move {
            error!(
                thread_id = error_ctx.thread_id,
                slot = error_ctx.slot,
                epoch = error_ctx.epoch,
                error = %error_ctx.error_message,
                "Firehose error"
            );
            Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
        }
        .boxed()
    };

    // Build StatsTracking value
    let stats_tracking = Some(StatsTracking {
        on_stats,
        tracking_interval_slots: 1000, // report every 1000 slots
    });

    let result = firehose(
        threads as u64,
        slot_start..slot_end,
        Some(on_block),
        Some(on_tx),
        Some(on_entry),
        Some(on_rewards),
        Some(on_error),
        stats_tracking,
        None,
    )
    .await;

    if let Err((error, slot)) = result {
        let error_msg = format!("{:?}", error);
        error!(
            slot = slot,
            error = %error_msg,
            "Firehose error"
        );
        return Err(format!("Firehose error at slot {}: {:?}", slot, error).into());
    }

    let elapsed = start_time.elapsed();
    let total_transactions = transaction_count.load(Ordering::Relaxed);
    let total_blocks = block_count.load(Ordering::Relaxed);

    info!(
        slot_start = slot_start,
        slot_end = slot_end,
        total_blocks = total_blocks,
        total_transactions = total_transactions,
        processing_time_secs = elapsed.as_secs_f64(),
        "Fetch completed successfully"
    );

    info!("SUCCESS — Old Faithful data fetch is working!");

    Ok(())
}
