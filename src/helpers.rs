use crate::multi_parser::{build_full_account_list, extract_instruction_type, try_parse};
use crate::storage::{ClickHouseStorage, FailedTransaction, Transaction};
use jetstreamer_firehose::firehose::TransactionData;
use solana_message::VersionedMessage;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Instant, SystemTime};
use yellowstone_vixen_core::instruction::InstructionUpdate;

// Calculate block_time from slot (Solana genesis: 2020-09-23 00:00:00 UTC = 1600646400)
const GENESIS_TIMESTAMP: u64 = 1600646400;
const SLOT_DURATION_SECONDS: f64 = 0.4; // ~400ms per slot

pub async fn process_transaction(
    tx: TransactionData,
    parser_map: &HashMap<Vec<u8>, &'static str>,
    metrics: &HashMap<String, (Arc<AtomicU64>, Arc<AtomicU64>)>,
    storage: &Arc<ClickHouseStorage>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let all_accounts = build_full_account_list(
        &tx.transaction.message,
        &tx.transaction_status_meta.loaded_addresses.writable,
        &tx.transaction_status_meta.loaded_addresses.readonly,
    );

    let instructions = match &tx.transaction.message {
        VersionedMessage::Legacy(msg) => &msg.instructions,
        VersionedMessage::V0(msg) => &msg.instructions,
    };

    // Check if transaction was successful on-chain
    // If transaction failed on-chain, skip it entirely (only store successful transactions)
    // status field is an enum: Ok(()) for success, Err(...) for failure
    let status_str = format!("{:?}", tx.transaction_status_meta.status);
    if status_str.starts_with("Err") {
        // Transaction failed on-chain, skip storing it
        return Ok(());
    }

    // Extract transaction metadata
    let signature = tx.signature.to_string();
    let fee = tx.transaction_status_meta.fee;
    let compute_units = tx.transaction_status_meta.compute_units_consumed.unwrap_or(0);
    
    // Calculate block_time from slot (Solana genesis: 2020-09-23 00:00:00 UTC = 1600646400)
    // Note: Slot duration is ~400ms, but actual block times can vary
    // Using calculated value as fallback, but prefer actual block_time if available
    let block_time = GENESIS_TIMESTAMP + ((tx.slot as f64 * SLOT_DURATION_SECONDS) as u64);
    
    // Extract log messages for failed transactions (for debugging)
    let log_messages: Vec<String> = tx
        .transaction_status_meta
        .log_messages
        .clone()
        .unwrap_or_default()
        .into_iter()
        .collect();
    let log_messages_str = log_messages.join("\n");
    
    // Calculate date and hour from block_time (using UTC timezone)
    // Ensure date matches block_time derivation for consistency with ClickHouse queries
    // ClickHouse's toDateTime(block_time) converts Unix timestamp to UTC DateTime
    // We use chrono::Utc to ensure UTC timezone matching
    let date = chrono::DateTime::<chrono::Utc>::from_timestamp(block_time as i64, 0)
        .map(|dt| dt.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| {
            // Fallback: if timestamp conversion fails, use epoch date
            // This should never happen for valid block_times
            "1970-01-01".to_string()
        });
    // Calculate hour in UTC (0-23) - matches ClickHouse's hour(toDateTime(block_time)) function
    let hour = ((block_time % 86400) / 3600) as u8;

    // Track instruction index (for future use if needed for deduplication)
    let mut _instruction_index = 0u16;
    for ix in instructions {
        let program_idx = ix.program_id_index as usize;
        if program_idx >= all_accounts.len() {
            continue;
        }
        let program_id = all_accounts[program_idx];
        let program_id_bytes = program_id.to_bytes();
        let program_id_str = bs58::encode(program_id_bytes.as_slice()).into_string();

        // Check if we have a parser for this program
        if let Some(parser_name) = parser_map.get(program_id_bytes.as_slice()) {
            // Resolve accounts
            let mut resolved_accounts = Vec::new();
            for account_idx in &ix.accounts {
                let idx = *account_idx as usize;
                if idx >= all_accounts.len() {
                    continue;
                }
                resolved_accounts.push(all_accounts[idx].to_bytes().into());
            }

            let instruction_update = InstructionUpdate {
                program: program_id_bytes.clone().into(),
                data: ix.data.clone(),
                accounts: resolved_accounts,
                shared: Default::default(),
                inner: vec![],
            };

            let raw_data = hex::encode(&ix.data);

            // Try parsing
            match try_parse(&instruction_update, parser_name).await {
                Ok(parsed_instruction) => {
                    if let Some((success, _)) = metrics.get(*parser_name) {
                        success.fetch_add(1, Ordering::Relaxed);
                    }

                    // Extract instruction type
                    let instruction_type = extract_instruction_type(&parsed_instruction);

                    // Insert successful transaction (transaction already verified as successful on-chain above)
                    // Note: Multiple instructions per transaction will create multiple rows with same signature
                    // This is intentional for instruction-level analytics, but means signatures are not unique
                    let tx_record = Transaction {
                        signature: signature.clone(),
                        slot: tx.slot,
                        block_time,
                        program_id: program_id_str.clone(),
                        protocol_name: parser_name.to_string(),
                        instruction_type,
                        success: 1, // Transaction was successful on-chain
                        fee,
                        compute_units,
                        accounts_count: ix.accounts.len() as u16,
                        date: date.clone(),
                        hour,
                    };

                    if let Err(e) = storage.insert_transaction(tx_record).await {
                        tracing::error!("Failed to insert transaction: {:?}", e);
                    }
                    
                    _instruction_index += 1;

                    // Note: transaction_payloads table removed to save storage space
                    // (was 1.32 GiB with no compression benefit, Debug strings aren't queryable)
                }
                Err(e) => {
                    if let Some((_, failed)) = metrics.get(*parser_name) {
                        failed.fetch_add(1, Ordering::Relaxed);
                    }

                    // Insert failed transaction
                    // Note: If transaction has multiple instructions, some may succeed (transactions table)
                    // and some may fail (failed_transactions table), causing same signature in both tables
                    // This is intentional for instruction-level tracking
                    let failed_tx = FailedTransaction {
                        signature: signature.clone(),
                        slot: tx.slot,
                        block_time,
                        program_id: program_id_str.clone(),
                        protocol_name: parser_name.to_string(),
                        raw_data,
                        error_message: format!("{:?}", e),
                        log_messages: log_messages_str.clone(),
                    };

                    if let Err(e) = storage.insert_failed(failed_tx).await {
                        tracing::error!("Failed to insert failed transaction: {:?}", e);
                    }
                    
                    _instruction_index += 1;
                }
            }
        }
    }

    Ok(())
}

pub fn print_summary(
    start_time: Instant,
    start_timestamp: SystemTime,
    end_time: Instant,
    end_timestamp: SystemTime,
    slot_start: u64,
    slot_end: u64,
    metrics: &HashMap<String, (Arc<AtomicU64>, Arc<AtomicU64>)>,
    threads: usize,
) {
    let elapsed = end_time.duration_since(start_time);
    let elapsed_secs = elapsed.as_secs_f64();
    let total_slots = slot_end - slot_start;
    let slots_per_second = total_slots as f64 / elapsed_secs;
    
    // Format timestamps (UNIX timestamp)
    let start_unix = start_timestamp.duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let end_unix = end_timestamp.duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    
    println!("\n=== Timing ===");
    println!("Start time: UNIX {} ({:.3}s before end)", start_unix, elapsed_secs);
    println!("End time:   UNIX {}", end_unix);
    println!("Elapsed:    {:.3}s", elapsed_secs);
    println!("Slots:      {} ({} to {})", total_slots, slot_start, slot_end);
    println!("Throughput: {:.2} slots/sec", slots_per_second);
    
    println!("\n=== Metrics ===");
    let mut total_success = 0;
    let mut total_failed = 0;
    
    // Sort by name for consistent output
    let mut sorted_names: Vec<_> = metrics.keys().collect();
    sorted_names.sort();
    
    for name in sorted_names {
        if let Some((success, failed)) = metrics.get(name) {
            let s = success.load(Ordering::Relaxed);
            let f = failed.load(Ordering::Relaxed);
            let t = s + f;
            total_success += s;
            total_failed += f;
            let failed_pct = if t > 0 { (f as f64 / t as f64) * 100.0 } else { 0.0 };
            println!("{}: {} success, {} failed, {} total ({:.2}% failed)", 
                name, s, f, t, failed_pct);
        }
    }
    
    let total = total_success + total_failed;
    let total_failed_pct = if total > 0 { (total_failed as f64 / total as f64) * 100.0 } else { 0.0 };
    println!("Total: {} success, {} failed, {} total ({:.2}% failed)", 
        total_success, total_failed, total, total_failed_pct
    );
    println!("Threads used: {}", threads);
}
