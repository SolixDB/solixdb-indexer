use crate::clickhouse::ClickHouseStorage;
use crate::types::{compute_time_dimensions, FailedTransaction, ProtocolEvent, Transaction, TransactionPayload};
use bs58;
use hex;
use solana_address::Address;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tracing::{error, info, warn};
use yellowstone_vixen_core::{instruction::InstructionUpdate, Parser};

struct ParserEntry {
    name: &'static str,
    parser: Arc<dyn ParserTrait>,
    counter: AtomicU64,
}

impl Clone for ParserEntry {
    fn clone(&self) -> Self {
        Self {
            name: self.name,
            parser: Arc::clone(&self.parser),
            counter: AtomicU64::new(self.counter.load(Ordering::Relaxed)),
        }
    }
}

trait ParserTrait: Send + Sync {
    fn parse_and_store<'a>(
        &'a self,
        instruction: &'a InstructionUpdate,
        parser_name: &'a str,
        signature: &'a str,
        slot: u64,
        block_time: u64,
        fee: u64,
        compute_units: u64,
        log_messages: &'a [String],
        storage: &'a ClickHouseStorage,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>>;
}

impl<P> ParserTrait for P
where
    P: Parser<Input = InstructionUpdate> + Send + Sync,
    P::Output: std::fmt::Debug + Send,
{
    fn parse_and_store<'a>(
        &'a self,
        instruction: &'a InstructionUpdate,
        parser_name: &'a str,
        signature: &'a str,
        slot: u64,
        block_time: u64,
        fee: u64,
        compute_units: u64,
        log_messages: &'a [String],
        storage: &'a ClickHouseStorage,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>> {
        let parser_name = parser_name.to_string();
        let signature = signature.to_string();
        let log_messages_str = log_messages.join("\n");

        Box::pin(async move {
            match self.parse(instruction).await {
                Ok(parsed) => {
                    let (date, hour, day_of_week) = compute_time_dimensions(block_time);
                    let tx = Transaction {
                        signature: signature.clone(),
                        slot,
                        block_time,
                        program_id: bs58::encode(&instruction.program).into_string(),
                        protocol_name: parser_name.clone(),
                        instruction_type: format!("{:?}", parsed)
                            .split('(')
                            .next()
                            .unwrap_or("Unknown")
                            .to_string(),
                        success: 1,
                        fee,
                        compute_units,
                        accounts_count: instruction.accounts.len() as u16,
                        date,
                        hour,
                        day_of_week,
                    };

                    if let Err(e) = storage.insert_transaction(tx).await {
                        error!("Failed to insert transaction: {:?}", e);
                    }

                    if let Err(e) = storage
                        .insert_payload(TransactionPayload {
                            signature: signature.clone(),
                            parsed_data: format!("{:?}", parsed),
                            raw_data: hex::encode(&instruction.data),
                            log_messages: log_messages_str.clone(),
                        })
                        .await
                    {
                        error!("Failed to insert payload: {:?}", e);
                    }

                    let parsed_str = format!("{:?}", parsed);
                    if let Some(event) = extract_protocol_event(
                        &parser_name,
                        &parsed_str,
                        &signature,
                        slot,
                        block_time,
                    ) {
                        if let Err(e) = storage.insert_protocol_event(event).await {
                            warn!("Failed to insert protocol event: {:?}", e);
                        }
                    }
                }
                Err(e) => {
                    warn!(
                        parser = parser_name,
                        signature = signature,
                        error = ?e,
                        "Parse failed"
                    );

                    let (date, hour, day_of_week) = compute_time_dimensions(block_time);

                    let tx = Transaction {
                        signature: signature.clone(),
                        slot,
                        block_time,
                        program_id: bs58::encode(&instruction.program).into_string(),
                        protocol_name: parser_name.clone(),
                        instruction_type: "ParseFailed".to_string(),
                        success: 0,
                        fee,
                        compute_units,
                        accounts_count: instruction.accounts.len() as u16,
                        date,
                        hour,
                        day_of_week,
                    };

                    if let Err(e) = storage.insert_transaction(tx).await {
                        error!("Failed to insert failed transaction: {:?}", e);
                    }

                    if let Err(e) = storage
                        .insert_failed_transaction(FailedTransaction {
                            signature: signature.clone(),
                            slot,
                            block_time,
                            program_id: bs58::encode(&instruction.program).into_string(),
                            protocol_name: parser_name.clone(),
                            raw_data: hex::encode(&instruction.data),
                            log_messages: log_messages_str,
                            error: format!("{:?}", e),
                        })
                        .await
                    {
                        error!("Failed to insert failed transaction record: {:?}", e);
                    }
                }
            }
        })
    }
}

fn extract_protocol_event(
    protocol: &str,
    parsed_data: &str,
    signature: &str,
    slot: u64,
    block_time: u64,
) -> Option<ProtocolEvent> {
    let event_type =
        if parsed_data.contains("Buy") || parsed_data.contains("Sell") {
            "trade"
        } else if parsed_data.contains("Swap") {
            "swap"
        } else if parsed_data.contains("AddLiquidity") {
            "liquidity_add"
        } else if parsed_data.contains("RemoveLiquidity") {
            "liquidity_remove"
        } else {
            "unknown"
        };
    
    Some(ProtocolEvent {
        signature: signature.to_string(),
        slot,
        block_time,
        protocol: protocol.to_lowercase(),
        event_type: event_type.to_string(),
        event_data: parsed_data.to_string(),
        amount_sol: 0,
        amount_token: 0,
        price: 0.0,
        user: "unknown".to_string(),
        mint: "unknown".to_string(),
    })
}

pub struct MultiParser {
    parsers: HashMap<Address, ParserEntry>,
    storage: Arc<ClickHouseStorage>,
}

impl MultiParser {
    pub async fn new(clickhouse_url: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let storage = ClickHouseStorage::new(clickhouse_url).await?;
        Ok(Self {
            parsers: HashMap::new(),
            storage: Arc::new(storage),
        })
    }

    pub fn add_parser<P>(mut self, program_id: &str, name: &'static str, parser: P) -> Self
    where
        P: Parser<Input = InstructionUpdate> + Send + Sync + 'static,
        P::Output: std::fmt::Debug + Send,
    {
        let address = program_id.parse().expect("Invalid program address");
        self.parsers.insert(
            address,
            ParserEntry {
                name,
                parser: Arc::new(parser),
                counter: AtomicU64::new(0),
            },
        );
        self
    }

    pub fn has_parser(&self, program_id: &Address) -> bool {
        self.parsers.contains_key(program_id)
    }

    pub async fn parse_instruction(
        &self,
        program_id: &Address,
        instruction: &InstructionUpdate,
        signature: &str,
        slot: u64,
        block_time: u64,
        fee: u64,
        compute_units: u64,
        log_messages: &[String],
    ) {
        if let Some(entry) = self.parsers.get(program_id) {
            entry
                .parser
                .parse_and_store(
                    instruction,
                    entry.name,
                    signature,
                    slot,
                    block_time,
                    fee,
                    compute_units,
                    log_messages,
                    &self.storage,
                )
                .await;
            entry.counter.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn parser_count(&self) -> usize {
        self.parsers.len()
    }

    pub fn list_parsers(&self) -> Vec<(&'static str, Address)> {
        self.parsers
            .iter()
            .map(|(addr, entry)| (entry.name, *addr))
            .collect()
    }

    pub async fn print_summary(&self) {
        info!("Transaction counts by parser:");
        for (_, entry) in &self.parsers {
            let count = entry.counter.load(Ordering::Relaxed);
            info!("  - {}: {} transactions", entry.name, count);
        }

        if let Err(e) = self.storage.get_storage_stats().await {
            error!("Failed to get storage stats: {:?}", e);
        }
    }

    pub async fn flush_all(&self) -> Result<(), Box<dyn std::error::Error>> {
        self.storage.flush_all().await
    }

    pub async fn clear_data(&self) -> Result<(), Box<dyn std::error::Error>> {
        self.storage.flush_all().await?;
        self.storage.clear_all_data().await
    }
}

