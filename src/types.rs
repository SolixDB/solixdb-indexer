use clickhouse::Row;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Row)]
pub struct Transaction {
    pub signature: String,
    pub slot: u64,
    pub block_time: u64,
    pub program_id: String,
    pub protocol_name: String,
    pub instruction_type: String,
    pub success: u8,
    pub fee: u64,
    pub compute_units: u64,
    pub accounts_count: u16,
    pub date: String,
    pub hour: u8,
    pub day_of_week: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, Row)]
pub struct TransactionPayload {
    pub signature: String,
    pub parsed_data: String,
    pub raw_data: String,
    pub log_messages: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Row)]
pub struct ProtocolEvent {
    pub signature: String,
    pub slot: u64,
    pub block_time: u64,
    pub protocol: String,
    pub event_type: String,
    pub event_data: String,
    pub amount_sol: u64,
    pub amount_token: u64,
    pub price: f64,
    pub user: String,
    pub mint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Row)]
pub struct FailedTransaction {
    pub signature: String,
    pub slot: u64,
    pub block_time: u64,
    pub program_id: String,
    pub protocol_name: String,
    pub raw_data: String,
    pub log_messages: String,
    pub error: String,
}

pub fn compute_time_dimensions(block_time: u64) -> (String, u8, u8) {
    if block_time == 0 {
        return ("1970-01-01".to_string(), 0, 0);
    }
    
    // Convert Unix timestamp to date components
    // Using a corrected algorithm that properly handles leap years
    let total_seconds = block_time;
    let hour = ((total_seconds % 86400) / 3600) as u8;
    
    // Calculate days since epoch
    let mut days = (total_seconds / 86400) as i64;
    let day_of_week = ((days + 4) % 7) as u8; // Jan 1, 1970 was a Thursday (4)
    
    // Calculate year, month, day
    let mut year = 1970;
    let mut remaining_days = days;
    
    // Handle years
    loop {
        let days_in_year = if is_leap_year(year) { 366 } else { 365 };
        if remaining_days >= days_in_year {
            remaining_days -= days_in_year;
            year += 1;
        } else {
            break;
        }
    }
    
    // Calculate month and day
    let month_days = if is_leap_year(year) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    
    let mut month = 1;
    let mut day = remaining_days as u32 + 1;
    
    for &days_in_month in &month_days {
        if day > days_in_month {
            day -= days_in_month;
            month += 1;
        } else {
            break;
        }
    }
    
    let date = format!("{:04}-{:02}-{:02}", year, month, day);
    (date, hour, day_of_week)
}

fn is_leap_year(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}

