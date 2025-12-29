mod clickhouse;
mod parser;
mod types;

use clickhouse::ClickHouseStorage;
use futures_util::FutureExt;
use jetstreamer_firehose::firehose::*;
use parser::MultiParser;
use solana_address::Address;
use solana_message::VersionedMessage;
use std::sync::Arc;
use std::time::Instant;
use tracing::{error, info};
use yellowstone_vixen_core::instruction::InstructionUpdate;
use yellowstone_vixen_jupiter_swap_parser::instructions_parser::InstructionParser as JupiterSwapIxParser;
use yellowstone_vixen_orca_whirlpool_parser::instructions_parser::InstructionParser as OrcaWhirlpoolIxParser;
use yellowstone_vixen_pump_swaps_parser::instructions_parser::InstructionParser as PumpSwapsIxParser;
use yellowstone_vixen_pumpfun_parser::instructions_parser::InstructionParser as PumpfunIxParser;
use yellowstone_vixen_raydium_amm_v4_parser::instructions_parser::InstructionParser as RaydiumAmmV4IxParser;
use yellowstone_vixen_raydium_clmm_parser::instructions_parser::InstructionParser as RaydiumClmmIxParser;
use yellowstone_vixen_raydium_cpmm_parser::instructions_parser::InstructionParser as RaydiumCpmmIxParser;

fn build_full_account_list(
    message: &VersionedMessage,
    loaded_writable: &[Address],
    loaded_readonly: &[Address],
) -> Vec<Address> {
    let mut all_accounts = Vec::new();
    match message {
        VersionedMessage::Legacy(msg) => {
            all_accounts.extend(msg.account_keys.clone());
        }
        VersionedMessage::V0(msg) => {
            all_accounts.extend(msg.account_keys.clone());
            all_accounts.extend(loaded_writable.iter().cloned());
            all_accounts.extend(loaded_readonly.iter().cloned());
        }
    }
    all_accounts
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_target(false)
        .with_thread_ids(false)
        .with_level(true)
        .init();

    info!("Starting SolixDB Data Collection");

    let slot_start = std::env::var("SLOT_START")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(377107390);
    
    let slot_end = std::env::var("SLOT_END")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(377108390);
    
    let threads = std::env::var("THREADS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);
    
    let network = std::env::var("NETWORK").unwrap_or_else(|_| "mainnet".to_string());
    let compact_index_base_url = std::env::var("COMPACT_INDEX_BASE_URL")
        .unwrap_or_else(|_| "https://files.old-faithful.net".to_string());
    let network_capacity_mb = std::env::var("NETWORK_CAPACITY_MB")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(100_000);
    
    let clickhouse_url = std::env::var("CLICKHOUSE_URL")
        .unwrap_or_else(|_| "http://localhost:8123".to_string());
    
    let clear_data_after = std::env::var("CLEAR_DATA_AFTER")
        .ok()
        .map(|s| s == "true")
        .unwrap_or(false);
    
    let clear_database_on_start = std::env::var("CLEAR_DB_ON_START")
        .ok()
        .map(|s| s == "true")
        .unwrap_or(true);

    if clear_database_on_start {
        info!("Clearing database and recreating tables with correct schema...");
        match ClickHouseStorage::new_with_clear(&clickhouse_url).await {
            Ok(_) => info!("Database cleared and tables recreated successfully"),
            Err(e) => {
                error!("Failed to clear database: {:?}", e);
                return Err(format!("Database initialization failed: {:?}", e).into());
            }
        }
    }

    let multi_parser = MultiParser::new(&clickhouse_url)
        .await?
        .add_parser(
            "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P",
            "Pumpfun",
            PumpfunIxParser,
        )
        .add_parser(
            "pAMMBay6oceH9fJKBRHGP5D4bD4sWpmSwMn52FMfXEA",
            "Pumpfun Swaps",
            PumpSwapsIxParser,
        )
        .add_parser(
            "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4",
            "Jupiter Swaps",
            JupiterSwapIxParser,
        )
        .add_parser(
            "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
            "Raydium AMM V4",
            RaydiumAmmV4IxParser,
        )
        .add_parser(
            "CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK",
            "Raydium CLMM",
            RaydiumClmmIxParser,
        )
        .add_parser(
            "CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C",
            "Raydium CPMM",
            RaydiumCpmmIxParser,
        )
        .add_parser(
            "whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc",
            "Orca Whirlpool",
            OrcaWhirlpoolIxParser,
        );

    info!("Active parsers:");
    for (name, program_id) in multi_parser.list_parsers() {
        info!("  - {} ({})", name, program_id);
    }

    let slot_range = slot_end - slot_start;
    info!(
        slot_start = slot_start,
        slot_end = slot_end,
        slot_range = slot_range,
        threads = threads,
        network = network,
        parser_count = multi_parser.parser_count(),
        clickhouse_url = clickhouse_url,
        "Configuration loaded"
    );
    

    unsafe {
        std::env::set_var("JETSTREAMER_NETWORK", network);
        std::env::set_var("JETSTREAMER_COMPACT_INDEX_BASE_URL", compact_index_base_url);
        std::env::set_var(
            "JETSTREAMER_NETWORK_CAPACITY_MB",
            network_capacity_mb.to_string(),
        );
    }

    info!("Starting data collection...");
    let start_time = Instant::now();

    let multi_parser: Arc<MultiParser> = Arc::new(multi_parser);
    let multi_parser_summary: Arc<MultiParser> = Arc::clone(&multi_parser);

    let transaction_handler = {
        let multi_parser = Arc::clone(&multi_parser);
        move |_thread_id: usize, tx: TransactionData| {
            let multi_parser = multi_parser.clone();
            async move {
                let all_accounts = build_full_account_list(
                    &tx.transaction.message,
                    &tx.transaction_status_meta.loaded_addresses.writable,
                    &tx.transaction_status_meta.loaded_addresses.readonly,
                );

                let instructions = match &tx.transaction.message {
                    VersionedMessage::Legacy(msg) => &msg.instructions,
                    VersionedMessage::V0(msg) => &msg.instructions,
                };

                // Extract transaction metadata
                let fee = tx.transaction_status_meta.fee;
                let compute_units = tx.transaction_status_meta.compute_units_consumed.unwrap_or(0);
                let log_messages: Vec<String> = tx
                    .transaction_status_meta
                    .log_messages
                    .clone()
                    .unwrap_or_default()
                    .into_iter()
                    .collect();
                // Calculate block_time from slot: Solana genesis was 2020-09-23 00:00:00 UTC (1600646400)
                // Genesis slot was 0, and each slot is ~400ms
                // block_time = genesis_timestamp + (slot * 0.4) seconds
                const GENESIS_TIMESTAMP: u64 = 1600646400; // 2020-09-23 00:00:00 UTC
                const SLOT_DURATION_SECONDS: f64 = 0.4; // ~400ms per slot
                let block_time = GENESIS_TIMESTAMP + ((tx.slot as f64 * SLOT_DURATION_SECONDS) as u64);

                for ix in instructions {
                    let program_idx = ix.program_id_index as usize;
                    if program_idx >= all_accounts.len() {
                        continue;
                    }
                    let program_id = all_accounts[program_idx];

                    if !multi_parser.has_parser(&program_id) {
                        continue;
                    }

                    let mut resolved_accounts = Vec::new();
                    for account_idx in &ix.accounts {
                        let idx = *account_idx as usize;
                        if idx >= all_accounts.len() {
                            continue;
                        }
                        resolved_accounts.push(all_accounts[idx].to_bytes().into());
                    }

                    let instruction_update = InstructionUpdate {
                        program: program_id.to_bytes().into(),
                        data: ix.data.clone(),
                        accounts: resolved_accounts,
                        shared: Default::default(),
                        inner: vec![],
                    };

                    multi_parser
                        .parse_instruction(
                            &program_id,
                            &instruction_update,
                            &tx.signature.to_string(),
                            tx.slot,
                            block_time,
                            fee,
                            compute_units,
                            &log_messages,
                        )
                        .await;
                }

                Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
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
            error!(
                thread_id = error_ctx.thread_id,
                slot = error_ctx.slot,
                error = %error_ctx.error_message,
                "Firehose error"
            );
            Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
        }
        .boxed()
    };

    let stats_handler = move |_thread_id: usize, stats: Stats| {
        async move {
            info!(
                slots = stats.slots_processed,
                blocks = stats.blocks_processed,
                txs = stats.transactions_processed,
                "Progress"
            );
            Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
        }
        .boxed()
    };

    let stats_tracking = Some(StatsTracking {
        on_stats: stats_handler,
        tracking_interval_slots: 1000,
    });

    let result = firehose(
        threads as u64,
        slot_start..slot_end,
        Some(block_handler),
        Some(transaction_handler),
        Some(entry_handler),
        Some(rewards_handler),
        Some(error_handler),
        stats_tracking,
        None,
    )
    .await;

    if let Err((error, slot)) = result {
        error!(slot = slot, error = ?error, "Firehose error");
        return Err(format!("Firehose error at slot {}: {:?}", slot, error).into());
    }

    let elapsed = start_time.elapsed();
    let slots_per_sec = slot_range as f64 / elapsed.as_secs_f64();

    info!(
        slot_range = format!("{}-{}", slot_start, slot_end),
        total_slots = slot_range,
        duration_secs = elapsed.as_secs_f64(),
        slots_per_sec = format!("{:.2}", slots_per_sec),
        threads = threads,
        "Data collection completed"
    );

    // Print summary
    multi_parser_summary.print_summary().await;

    // Flush all pending batches
    info!("Flushing all pending batches...");
    if let Err(e) = (*multi_parser_summary).flush_all().await {
        error!("Failed to flush batches: {:?}", e);
    }


    // Clear data if requested
    if clear_data_after {
        info!("Clearing all data as requested...");
        if let Err(e) = multi_parser_summary.clear_data().await {
            error!("Failed to clear data: {:?}", e);
        } else {
            info!("All data cleared successfully");
        }
    }

    Ok(())
}
