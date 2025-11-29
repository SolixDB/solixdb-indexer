use solana_address::Address;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tracing::{error, info};
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
    fn parse_and_log<'a>(
        &'a self,
        instruction: &'a InstructionUpdate,
        parser_name: &'a str,
        signature: &'a str,
        slot: u64,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>>;
}

impl<P> ParserTrait for P
where
    P: Parser<Input = InstructionUpdate> + Send + Sync,
    P::Output: std::fmt::Debug,
{
    fn parse_and_log<'a>(
        &'a self,
        instruction: &'a InstructionUpdate,
        parser_name: &'a str,
        signature: &'a str,
        slot: u64,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>> {
        let parser_name = parser_name.to_string();
        let signature = signature.to_string();
        Box::pin(async move {
            match self.parse(instruction).await {
                Ok(parsed) => info!(
                    parser = parser_name,
                    signature = signature,
                    slot = slot,
                    parsed = ?parsed,
                    "Instruction parsed"
                ),
                Err(e) => error!(
                    parser = parser_name,
                    signature = signature,
                    error = ?e,
                    "Parse error"
                ),
            }
        })
    }
}

#[derive(Clone)]
pub struct MultiParser {
    parsers: HashMap<Address, ParserEntry>,
}

impl MultiParser {
    pub fn new() -> Self {
        Self {
            parsers: HashMap::new(),
        }
    }

    pub fn add_parser<P>(mut self, program_id: &str, name: &'static str, parser: P) -> Self
    where
        P: Parser<Input = InstructionUpdate> + Send + Sync + 'static,
        P::Output: std::fmt::Debug,
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
    ) {
        if let Some(entry) = self.parsers.get(program_id) {
            entry
                .parser
                .parse_and_log(instruction, entry.name, signature, slot)
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

    pub fn print_summary(&self) {
        info!("Transaction counts by parser:");
        for (_, entry) in &self.parsers {
            let count = entry.counter.load(Ordering::Relaxed);
            info!("  - {}: {} transactions", entry.name, count);
        }
    }
}