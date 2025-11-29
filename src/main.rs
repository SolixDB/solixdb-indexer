use futures_util::FutureExt;
use jetstreamer_firehose::firehose::*;
use solana_address::Address;
use solana_message::VersionedMessage;
use std::sync::Arc;
use std::time::Instant;
use tracing::{error, info};
use yellowstone_vixen_core::{instruction::InstructionUpdate};
use yellowstone_vixen_pumpfun_parser::instructions_parser::InstructionParser as PumpfunIxParser;
use yellowstone_vixen_raydium_amm_v4_parser::instructions_parser::InstructionParser as RaydiumAmmV4IxParser;
use yellowstone_vixen_raydium_clmm_parser::instructions_parser::InstructionParser as RaydiumClmmIxParser;
use yellowstone_vixen_raydium_cpmm_parser::instructions_parser::InstructionParser as RaydiumCpmmIxParser;
use yellowstone_vixen_raydium_launchpad_parser::instructions_parser::InstructionParser as RaydiumLaunchpadIxParser;

mod multi_parser;
use multi_parser::MultiParser;

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

    info!("Starting Multi-Parser Transaction Logger");

    // Configuration
    let slot_start = 345000000;
    let slot_end = 345000001;
    let threads = 1;
    let network = "mainnet";
    let compact_index_base_url = "https://files.old-faithful.net";
    let network_capacity_mb = 100_000;

    // Initialize multi-parser with all your parsers
    let multi_parser = MultiParser::new()
        .add_parser(
            "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P",
            "Pumpfun",
            PumpfunIxParser,
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
            "LanMV9sAd7wArD4vJFi2qDdfnVhFxYSUg6eADduJ3uj",
            "Raydium Launchpad",
            RaydiumLaunchpadIxParser,
        );

    // Log active parsers
    info!("Active parsers:");
    for (name, program_id) in multi_parser.list_parsers() {
        info!("  - {} ({})", name, program_id);
    }

    info!(
        slot_start = slot_start,
        slot_end = slot_end,
        threads = threads,
        network = network,
        parser_count = multi_parser.parser_count(),
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

    info!("Starting data fetch from Old Faithful...");
    let start_time = Instant::now();

    // Create Arc for shared access during processing and summary
    let multi_parser = Arc::new(multi_parser);
    let multi_parser_summary = Arc::clone(&multi_parser);

    let block_handler = move |_thread_id: usize, _block: BlockData| {
        async move { Ok::<(), Box<dyn std::error::Error + Send + Sync>>(()) }.boxed()
    };

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

                // Process all instructions
                for ix in instructions {
                    let program_idx = ix.program_id_index as usize;
                    if program_idx >= all_accounts.len() {
                        continue;
                    }

                    let program_id = all_accounts[program_idx];

                    // Check if we have a parser for this program
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

                    // Parse the instruction
                    multi_parser
                        .parse_instruction(
                            &program_id,
                            &instruction_update,
                            &tx.signature.to_string(),
                            tx.slot,
                        )
                        .await;
                }

                Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
            }
            .boxed()
        }
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
        tracking_interval_slots: 10000,
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

    info!(
        slot_range = format!("{}-{}", slot_start, slot_end),
        duration_secs = elapsed.as_secs_f64(),
        "Processing completed"
    );

    // Print summary for each parser
    multi_parser_summary.print_summary();

    Ok(())
}
