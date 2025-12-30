use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub slots: SlotConfig,
    pub clickhouse: ClickHouseConfig,
    pub processing: ProcessingConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlotConfig {
    pub start: u64,
    pub end: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClickHouseConfig {
    pub url: String,
    pub clear_on_start: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessingConfig {
    pub threads: usize,
}

impl Config {
    /// Load configuration from file and environment variables
    /// Environment variables override config file values
    pub fn load() -> Result<Self, Box<dyn std::error::Error>> {
        let config_path = Path::new("config.toml");
        let mut config = if config_path.exists() {
            tracing::info!("Loading configuration from config.toml");
            let content = std::fs::read_to_string(config_path)
                .map_err(|e| format!("Failed to read config.toml: {}", e))?;
            toml::from_str::<Config>(&content)
                .map_err(|e| format!("Failed to parse config.toml: {}. Please check TOML syntax.", e))?
        } else {
            tracing::info!("config.toml not found, using default configuration");
            Config::default()
        };

        // Override with environment variables
        if let Ok(val) = std::env::var("SLOT_START") {
            if let Ok(parsed) = val.parse::<u64>() {
                config.slots.start = parsed;
            }
        }

        if let Ok(val) = std::env::var("SLOT_END") {
            if let Ok(parsed) = val.parse::<u64>() {
                config.slots.end = parsed;
            }
        }

        if let Ok(val) = std::env::var("CLICKHOUSE_URL") {
            config.clickhouse.url = val;
        }

        if let Ok(val) = std::env::var("CLEAR_DB_ON_START") {
            config.clickhouse.clear_on_start = val == "true";
        }

        if let Ok(val) = std::env::var("THREADS") {
            if let Ok(parsed) = val.parse::<usize>() {
                config.processing.threads = parsed;
            }
        }

        // Validate
        if config.slots.start >= config.slots.end {
            return Err(format!(
                "Invalid slot range: start ({}) must be less than end ({})",
                config.slots.start, config.slots.end
            ).into());
        }

        if config.processing.threads == 0 {
            return Err("THREADS must be greater than 0".into());
        }

        Ok(config)
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            slots: SlotConfig {
                start: 383639270,
                end: 383639271,
            },
            clickhouse: ClickHouseConfig {
                url: "http://localhost:8123".to_string(),
                clear_on_start: false,
            },
            processing: ProcessingConfig {
                threads: 1,
            },
        }
    }
}

