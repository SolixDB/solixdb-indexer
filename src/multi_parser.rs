use solana_address::Address;
use solana_message::VersionedMessage;
use std::collections::HashMap;
use yellowstone_vixen_core::instruction::InstructionUpdate;
use yellowstone_vixen_core::Parser;
use yellowstone_vixen_proc_macro::include_vixen_parser;

include_vixen_parser!("idls/jupiter_v6.json");
include_vixen_parser!("idls/jupiter_v4.json");
include_vixen_parser!("idls/pumpfun_swaps.json");
include_vixen_parser!("idls/pump_fun.json");
include_vixen_parser!("idls/raydium_amm_v3.json");
include_vixen_parser!("idls/raydium_cpmm.json");
include_vixen_parser!("idls/orca_whirlpool.json");

pub fn build_full_account_list(
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

pub async fn try_parse(
    update: &InstructionUpdate,
    parser_name: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    match parser_name {
        "jupiter_v6" => {
            jupiter_v6::InstructionParser.parse(update).await
                .map(|inst| format!("{:?}", inst))
                .map_err(|e| format!("{:?}", e).into())
        }
        "jupiter_v4" => {
            jupiter_v4::InstructionParser.parse(update).await
                .map(|inst| format!("{:?}", inst))
                .map_err(|e| format!("{:?}", e).into())
        }
        "pump_amm" => {
            pump_amm::InstructionParser.parse(update).await
                .map(|inst| format!("{:?}", inst))
                .map_err(|e| format!("{:?}", e).into())
        }
        "pump_fun" => {
            pump_fun::InstructionParser.parse(update).await
                .map(|inst| format!("{:?}", inst))
                .map_err(|e| format!("{:?}", e).into())
        }
        "raydium_amm_v3" => {
            amm_v3::InstructionParser.parse(update).await
                .map(|inst| format!("{:?}", inst))
                .map_err(|e| format!("{:?}", e).into())
        }
        "raydium_cp_swap" => {
            raydium_cp_swap::InstructionParser.parse(update).await
                .map(|inst| format!("{:?}", inst))
                .map_err(|e| format!("{:?}", e).into())
        }
        "whirlpool" => {
            whirlpool::InstructionParser.parse(update).await
                .map(|inst| format!("{:?}", inst))
                .map_err(|e| format!("{:?}", e).into())
        }
        _ => Err(format!("Unknown parser: {}", parser_name).into()),
    }
}

/// Extract instruction type name from parsed instruction string
/// Format: "InstructionName { ... }" -> "InstructionName"
pub fn extract_instruction_type(parsed: &str) -> String {
    parsed
        .split('{')
        .next()
        .unwrap_or(parsed)
        .trim()
        .to_string()
}

pub fn build_parser_map() -> HashMap<Vec<u8>, &'static str> {
    let mut map = HashMap::new();
    
    // 1. Jupiter v6
    map.insert(
        bs58::decode("JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4").into_vec().unwrap(),
        "jupiter_v6",
    );
    // 2. Jupiter v4
    map.insert(
        bs58::decode("JUP4Fb2cqiRUcaTHdrPC8h2gNsA2ETXiPDD33WcGuJB").into_vec().unwrap(),
        "jupiter_v4",
    );
    // 3. Pump Amm
    map.insert(
        bs58::decode("pAMMBay6oceH9fJKBRHGP5D4bD4sWpmSwMn52FMfXEA").into_vec().unwrap(),
        "pump_amm",
    );
    // 4. Pump fun
    map.insert(
        bs58::decode("6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P").into_vec().unwrap(),
        "pump_fun",
    );
    // 5. Raydium AMM V3
    map.insert(
        bs58::decode("CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK").into_vec().unwrap(),
        "raydium_amm_v3",
    );
    // 6. Raydium CP Swap
    map.insert(
        bs58::decode("CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C").into_vec().unwrap(),
        "raydium_cp_swap",
    );
    // 7. Whirlpool
    map.insert(
        bs58::decode("whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc").into_vec().unwrap(),
        "whirlpool",
    );
    
    map
}
