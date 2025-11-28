use futures_util::FutureExt;
use jetstreamer_firehose::firehose::*;
use serde::{Deserialize, Serialize};
use solana_address::Address;
use solana_message::VersionedMessage;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use std::time::Instant;
use tracing::{error, info};
use yellowstone_vixen_core::{instruction::InstructionUpdate, Parser};
use yellowstone_vixen_raydium_amm_v4_parser::instructions_parser::InstructionParser as RaydiumIxParser;

#[derive(Serialize, Deserialize)]
struct TransactionRecord {
    signature: String,
    slot: u64,
    transaction_slot_index: u32,
    is_vote: bool,
    compute_units_consumed: Option<u64>,
    error: Option<String>,
    account_keys: Vec<String>,
    instructions: Vec<InstructionRecord>,
}

#[derive(Serialize, Deserialize)]
struct InstructionRecord {
    program_id_index: u8,
    accounts: Vec<u8>,
    data: String,
}

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

    info!("Starting Old Faithful transaction logger");

    let slot_start = 345000000;
    let slot_end = 345000001;
    let threads = 1;
    let network = "mainnet";
    let compact_index_base_url = "https://files.old-faithful.net";
    let network_capacity_mb = 100_000;

    let raydium_program_id = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"
        .parse::<Address>()
        .expect("Invalid program address");

    info!(
        slot_start = slot_start,
        slot_end = slot_end,
        threads = threads,
        network = network,
        target_program = %raydium_program_id,
        "Configuration loaded"
    );

    unsafe {
        std::env::set_var("JETSTREAMER_NETWORK", network);
        std::env::set_var("JETSTREAMER_COMPACT_INDEX_BASE_URL", compact_index_base_url);
        std::env::set_var("JETSTREAMER_NETWORK_CAPACITY_MB", network_capacity_mb.to_string());
    }

    let transaction_count = Arc::new(AtomicU64::new(0));
    let block_count = Arc::new(AtomicU64::new(0));
    let raydium_count = Arc::new(AtomicU64::new(0));

    info!("Starting data fetch from Old Faithful...");
    let start_time = Instant::now();

    let block_handler = {
        let block_count = block_count.clone();
        move |_thread_id: usize, block: BlockData| {
            let block_count = block_count.clone();
            async move {
                match block {
                    BlockData::Block { slot, blockhash, executed_transaction_count, .. } => {
                        let count = block_count.fetch_add(1, Ordering::Relaxed);
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
        }
    };

    let transaction_handler = {
        let transaction_count = transaction_count.clone();
        let raydium_count = raydium_count.clone();
        let raydium_parser = Arc::new(RaydiumIxParser);

        move |_thread_id: usize, tx: TransactionData| {
            let transaction_count = transaction_count.clone();
            let raydium_count = raydium_count.clone();
            let raydium_parser = raydium_parser.clone();

            async move {
                let count = transaction_count.fetch_add(1, Ordering::Relaxed);
                
                info!(
                    count = count,
                    signature = %tx.signature,
                    slot = tx.slot,
                    index = tx.transaction_slot_index,
                    is_vote = tx.is_vote,
                    "Transaction"
                );

                let all_accounts = build_full_account_list(
                    &tx.transaction.message,
                    &tx.transaction_status_meta.loaded_addresses.writable,
                    &tx.transaction_status_meta.loaded_addresses.readonly,
                );

                let instructions = match &tx.transaction.message {
                    VersionedMessage::Legacy(msg) => &msg.instructions,
                    VersionedMessage::V0(msg) => &msg.instructions,
                };

                let uses_raydium = instructions
                    .iter()
                    .filter_map(|ix| all_accounts.get(ix.program_id_index as usize))
                    .any(|program_id| *program_id == raydium_program_id);

                if uses_raydium {
                    info!(signature = %tx.signature, "Found Raydium transaction");

                    for ix in instructions {
                        let program_idx = ix.program_id_index as usize;
                        
                        if program_idx >= all_accounts.len() {
                            error!(
                                signature=%tx.signature,
                                program_idx,
                                total_accounts=all_accounts.len(),
                                "Invalid program_id_index"
                            );
                            continue;
                        }

                        let program_id = all_accounts[program_idx];
                        if program_id != raydium_program_id {
                            continue;
                        }

                        let mut resolved_accounts = Vec::new();
                        for account_idx in &ix.accounts {
                            let idx = *account_idx as usize;
                            if idx >= all_accounts.len() {
                                error!(
                                    signature=%tx.signature,
                                    account_idx=idx,
                                    total_accounts=all_accounts.len(),
                                    "Invalid account index"
                                );
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

                        match raydium_parser.parse(&instruction_update).await {
                            Ok(parsed) => info!(parsed=?parsed, "Raydium parsed"),
                            Err(e) => error!(error=?e, "Raydium parse error"),
                        }
                    }

                    raydium_count.fetch_add(1, Ordering::Relaxed);
                }

                if count > 0 && count % 100 == 0 {
                    info!(count, "Progress: {} transactions processed", count);
                }

                Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
            }
            .boxed()
        }
    };

    let entry_handler = move |_thread_id: usize, entry: EntryData| {
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

    let rewards_handler = move |_thread_id: usize, rewards: RewardsData| {
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

    let stats_handler = move |_thread_id: usize, stats: Stats| {
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

    let error_handler = move |_thread_id: usize, error_ctx: FirehoseErrorContext| {
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
        let error_msg = format!("{:?}", error);
        error!(slot = slot, error = %error_msg, "Firehose error");
        return Err(format!("Firehose error at slot {}: {:?}", slot, error).into());
    }

    let elapsed = start_time.elapsed();
    let total_transactions = transaction_count.load(Ordering::Relaxed);
    let total_blocks = block_count.load(Ordering::Relaxed);
    let total_raydium = raydium_count.load(Ordering::Relaxed);

    info!(
        slot_start = slot_start,
        slot_end = slot_end,
        total_blocks = total_blocks,
        total_transactions = total_transactions,
        processing_time_secs = elapsed.as_secs_f64(),
        "Fetch completed successfully"
    );

    info!("Raydium program transactions found: {}", total_raydium);
    info!("SUCCESS — Old Faithful data fetch is working!");

    Ok(())
}