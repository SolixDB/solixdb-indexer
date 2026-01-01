-- ============================================================================
-- SolixDB Data Quality Validation Queries
-- ============================================================================
-- This file contains comprehensive validation queries for 10 key use cases.
-- Each use case includes checks for:
--   1. Data Completeness (no gaps in critical fields)
--   2. Data Accuracy (values in expected ranges)
--   3. Data Consistency (relationships between tables valid)
--   4. Query Performance (indexes working, queries fast)
--
-- IMPORTANT: Data Model - Instruction-Level Storage
-- ==================================================
-- This system stores INSTRUCTION-LEVEL data, not transaction-level data.
-- 
-- Key implications:
-- - One transaction can have multiple instructions
-- - Each instruction creates a separate row with the SAME signature
-- - Signatures are NOT unique (expected behavior for instruction-level analytics)
-- - A transaction signature may appear in BOTH tables if:
--   * Some instructions parse successfully (→ transactions table)
--   * Some instructions fail to parse (→ failed_transactions table)
-- 
-- This design enables:
-- - Instruction-level analytics (filter by protocol/instruction type)
-- - Better granularity for analytics dashboards
-- - Per-instruction error tracking
--
-- IMPORTANT: Schema - MATERIALIZED Columns
-- =========================================
-- The `date` and `hour` columns are MATERIALIZED and automatically calculated:
-- - date: Date MATERIALIZED toDate(block_time)
-- - hour: UInt8 MATERIALIZED toHour(toDateTime(block_time))
-- These are computed by ClickHouse from block_time, ensuring 100% consistency.
-- No need to calculate or validate these in application code.
--
-- Run these queries periodically to ensure data quality for production APIs.
-- ============================================================================

-- ============================================================================
-- USE CASE 1: Protocol Analytics (Dune-style Dashboards)
-- ============================================================================
-- Use Case: Filter transactions by protocol_name for analytics dashboards
-- Expected Queries: SELECT * FROM transactions WHERE protocol_name = 'Jupiter'
-- Critical Fields: protocol_name, date, slot, signature

-- 1.1 Data Completeness: Check for NULL or empty protocol_name
SELECT 
    'USE CASE 1.1: NULL protocol_name check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE protocol_name IS NULL OR protocol_name = '';

-- 1.2 Data Accuracy: Verify protocol_name values are valid (not placeholder values)
SELECT 
    'USE CASE 1.2: Invalid protocol_name values' AS validation,
    protocol_name,
    COUNT(*) AS count
FROM transactions
WHERE protocol_name IN ('unknown', 'Unknown', 'UNKNOWN', '', 'N/A', 'null')
GROUP BY protocol_name
ORDER BY count DESC;

-- 1.3 Data Consistency: Ensure protocol_name matches expected format (no special chars)
SELECT 
    'USE CASE 1.3: Protocol name format validation' AS validation,
    COUNT(*) AS invalid_format_count
FROM transactions
WHERE protocol_name != '' 
    AND (
        protocol_name LIKE '%\n%' 
        OR protocol_name LIKE '%\r%'
        OR protocol_name LIKE '%\t%'
        OR length(protocol_name) > 100
    );

-- 1.4 Query Performance: Test protocol_name filter with bloom filter index
-- Expected: Should use idx_protocol_name bloom filter, < 100ms for common protocols
EXPLAIN PLAN
SELECT 
    protocol_name,
    COUNT(*) AS tx_count,
    SUM(fee) AS total_fees,
    AVG(compute_units) AS avg_compute_units
FROM transactions
WHERE protocol_name = 'Jupiter'
    AND date >= toDate('2024-01-01')
GROUP BY protocol_name;

-- 1.5 Data Completeness: Check date field is valid (not NULL or invalid)
-- NOTE: date is now Date type (MATERIALIZED from block_time), so format validation is automatic
SELECT 
    'USE CASE 1.5: Date validity check' AS validation,
    COUNT(*) AS invalid_date_count
FROM transactions
WHERE date IS NULL 
    OR date < toDate('2020-01-01')  -- Before Solana mainnet
    OR date > today() + 1;  -- Not in future

-- ============================================================================
-- USE CASE 2: Program-Level Analytics
-- ============================================================================
-- Use Case: Track transactions by specific program_id (e.g., Token Program, System Program)
-- Expected Queries: SELECT * FROM transactions WHERE program_id = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA'
-- Critical Fields: program_id, slot, block_time

-- 2.1 Data Completeness: Check for NULL or empty program_id
SELECT 
    'USE CASE 2.1: NULL program_id check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE program_id IS NULL OR program_id = '';

-- 2.2 Data Accuracy: Verify program_id format (Solana addresses are base58, 32-44 chars)
SELECT 
    'USE CASE 2.2: Invalid program_id format' AS validation,
    COUNT(*) AS invalid_format_count
FROM transactions
WHERE program_id != ''
    AND (length(program_id) < 32 OR length(program_id) > 44);

-- 2.3 Data Consistency: Check program_id appears in both transactions and failed_transactions
SELECT 
    'USE CASE 2.3: Program ID consistency check' AS validation,
    t.program_id,
    COUNT(DISTINCT 'tx') AS in_transactions,
    COUNT(DISTINCT 'failed') AS in_failed
FROM (
    SELECT DISTINCT program_id FROM transactions WHERE program_id != ''
    UNION ALL
    SELECT DISTINCT program_id FROM failed_transactions WHERE program_id != ''
) t
GROUP BY t.program_id
HAVING COUNT(DISTINCT 'tx') = 0 OR COUNT(DISTINCT 'failed') = 0
LIMIT 10;

-- 2.4 Query Performance: Test program_id filter with bloom filter index
-- Expected: Should use idx_program_id bloom filter, < 200ms for common programs
EXPLAIN PLAN
SELECT 
    program_id,
    COUNT(*) AS tx_count,
    SUM(success) AS successful_count,
    COUNT(*) - SUM(success) AS failed_count
FROM transactions
WHERE program_id = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA'
    AND slot >= 377107390
GROUP BY program_id;

-- 2.5 Data Accuracy: Verify block_time is within reasonable range (not 0, not future)
SELECT 
    'USE CASE 2.5: Block time range validation' AS validation,
    COUNT(*) AS invalid_block_time_count
FROM transactions
WHERE block_time = 0 
    OR block_time > toUnixTimestamp(now())
    OR block_time < 1609459200; -- Jan 1, 2021 (Solana mainnet launch)

-- ============================================================================
-- USE CASE 3: Transaction Signature Lookup (REST API)
-- ============================================================================
-- Use Case: Lookup specific transaction by signature for REST/GraphQL APIs
-- Expected Queries: SELECT * FROM transactions WHERE signature = '5VERv8NMvzbJMEkV8xnrLkEaWRtSz9CosKDYjCJjBRnbJLgp8uirBgmQpjKhoR4LfDvyvVgVfuiUNzWktif6Vw28'
-- Critical Fields: signature, slot, block_time

-- 3.1 Data Completeness: Check for NULL or empty signatures
SELECT 
    'USE CASE 3.1: NULL signature check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE signature IS NULL OR signature = '';

-- 3.2 Data Accuracy: Verify signature format (base58, typically 88 chars)
SELECT 
    'USE CASE 3.2: Invalid signature format' AS validation,
    COUNT(*) AS invalid_format_count
FROM transactions
WHERE signature != ''
    AND (length(signature) < 80 OR length(signature) > 100);

-- 3.3 Data Consistency: Check signature distribution (duplicates are expected)
-- NOTE: Duplicates are EXPECTED for instruction-level data model
-- One transaction can have multiple instructions, each creating a row with same signature
-- This query shows the distribution of instructions per transaction signature
SELECT 
    'USE CASE 3.3: Signature distribution (instruction-level model)' AS validation,
    (SELECT COUNT(DISTINCT signature) FROM transactions) AS unique_signatures,
    (SELECT COUNT(*) FROM transactions) AS total_instruction_rows,
    (SELECT COUNT(*) FROM transactions) / greatest((SELECT COUNT(DISTINCT signature) FROM transactions), 1) AS avg_instructions_per_signature,
    (SELECT MAX(instruction_count) FROM (
        SELECT signature, COUNT(*) AS instruction_count
        FROM transactions
        GROUP BY signature
    )) AS max_instructions_per_signature;

-- 3.4 Query Performance: Test signature lookup with bloom filter index
-- Expected: Should use idx_signature bloom filter, < 50ms for single signature lookup
EXPLAIN PLAN
SELECT 
    signature,
    slot,
    block_time,
    protocol_name,
    instruction_type,
    success,
    fee
FROM transactions
WHERE signature = '5VERv8NMvzbJMEkV8xnrLkEaWRtSz9CosKDYjCJjBRnbJLgp8uirBgmQpjKhoR4LfDvyvVgVfuiUNzWktif6Vw28';

-- 3.5 Data Consistency: Check signature cross-table distribution (expected for instruction-level)
-- NOTE: Cross-table presence is EXPECTED for instruction-level data model
-- If a transaction has multiple instructions:
--   - Some instructions parse successfully → transactions table
--   - Some instructions fail to parse → failed_transactions table
-- This query shows how many signatures appear in both tables (expected behavior)
SELECT 
    'USE CASE 3.5: Signature cross-table distribution (instruction-level model)' AS validation,
    COUNT(DISTINCT t.signature) AS signatures_in_both_tables,
    COUNT(DISTINCT t.signature) * 100.0 / greatest(COUNT(DISTINCT t.signature), 1) AS percentage_with_mixed_results,
    COUNT(*) AS total_instruction_rows_with_mixed_results
FROM transactions t
INNER JOIN failed_transactions f ON t.signature = f.signature;

-- ============================================================================
-- USE CASE 4: Time-Based Analytics (Time Series)
-- ============================================================================
-- Use Case: Query transactions by date/hour for time series analysis
-- Expected Queries: SELECT * FROM transactions WHERE date = toDate('2024-12-30') AND hour = 14
-- Critical Fields: date (Date MATERIALIZED), hour (UInt8 MATERIALIZED), block_time

-- 4.1 Data Completeness: Check for NULL or missing date/hour values
-- NOTE: date and hour are now MATERIALIZED columns, so they should never be NULL if block_time is valid
SELECT 
    'USE CASE 4.1: NULL date/hour check' AS validation,
    COUNT(*) AS null_date_count,
    COUNT(*) AS null_hour_count
FROM transactions
WHERE date IS NULL OR hour IS NULL;

-- 4.2 Data Accuracy: Verify hour is in valid range (0-23)
SELECT 
    'USE CASE 4.2: Invalid hour range' AS validation,
    hour,
    COUNT(*) AS count
FROM transactions
WHERE hour > 23 OR hour < 0
GROUP BY hour;

-- 4.3 Data Consistency: Verify date matches block_time (date is MATERIALIZED from block_time)
-- NOTE: Since date is now MATERIALIZED as toDate(block_time), this should always be 0
-- This validates that the MATERIALIZED column is working correctly
SELECT 
    'USE CASE 4.3: Date/block_time consistency' AS validation,
    COUNT(*) AS inconsistent_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions WHERE block_time > 0) AS inconsistency_percentage
FROM transactions
WHERE date != toDate(block_time)
    AND block_time > 0;

-- 4.4 Query Performance: Test date/hour filter with partition pruning
-- Expected: Should use partition pruning on date, < 500ms for daily queries
EXPLAIN PLAN
SELECT 
    date,
    hour,
    COUNT(*) AS tx_count,
    SUM(fee) AS total_fees,
    AVG(compute_units) AS avg_compute_units
FROM transactions
WHERE date = toDate('2024-12-30')
    AND hour BETWEEN 10 AND 14
GROUP BY date, hour
ORDER BY hour;

-- 4.5 Data Completeness: Check for gaps in date coverage (missing dates)
SELECT 
    'USE CASE 4.5: Date coverage gaps' AS validation,
    min_date,
    max_date,
    expected_days,
    actual_days,
    expected_days - actual_days AS missing_days
FROM (
    SELECT 
        min(date) AS min_date,
        max(date) AS max_date,
        dateDiff('day', min(date), max(date)) + 1 AS expected_days,
        COUNT(DISTINCT date) AS actual_days
    FROM transactions
    WHERE date IS NOT NULL
);

-- ============================================================================
-- USE CASE 5: Success Rate Monitoring
-- ============================================================================
-- Use Case: Monitor transaction success rates by protocol/program
-- Expected Queries: SELECT protocol_name, SUM(success) / COUNT(*) AS success_rate FROM transactions GROUP BY protocol_name
-- Critical Fields: success, protocol_name, program_id

-- 5.1 Data Completeness: Check for NULL success values
SELECT 
    'USE CASE 5.1: NULL success check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE success IS NULL;

-- 5.2 Data Accuracy: Verify success is binary (0 or 1 only)
SELECT 
    'USE CASE 5.2: Invalid success values' AS validation,
    success,
    COUNT(*) AS count
FROM transactions
WHERE success NOT IN (0, 1)
GROUP BY success;

-- 5.3 Data Consistency: Verify all transactions have success=1 (we filter failed on-chain txs)
-- Note: This should be 100% since we only store successful on-chain transactions
SELECT 
    'USE CASE 5.3: Success rate validation' AS validation,
    COUNT(*) AS total_txs,
    SUM(success) AS successful_txs,
    COUNT(*) - SUM(success) AS failed_txs,
    (SUM(success) * 100.0 / COUNT(*)) AS success_rate_percentage
FROM transactions;

-- 5.4 Query Performance: Test success rate aggregation query
-- Expected: Should be fast with proper indexes, < 1s for protocol-level aggregation
EXPLAIN PLAN
SELECT 
    protocol_name,
    COUNT(*) AS total_txs,
    SUM(success) AS successful_txs,
    (SUM(success) * 100.0 / COUNT(*)) AS success_rate
FROM transactions
WHERE date >= toDate('2024-12-01')
GROUP BY protocol_name
ORDER BY total_txs DESC
LIMIT 20;

-- 5.5 Data Consistency: Compare success rates between protocols
SELECT 
    'USE CASE 5.5: Protocol success rate comparison' AS validation,
    protocol_name,
    COUNT(*) AS tx_count,
    (SUM(success) * 100.0 / COUNT(*)) AS success_rate
FROM transactions
WHERE protocol_name != ''
GROUP BY protocol_name
HAVING COUNT(*) > 100
ORDER BY success_rate ASC
LIMIT 10;

-- ============================================================================
-- USE CASE 6: Fee Analysis
-- ============================================================================
-- Use Case: Analyze transaction fees for cost tracking and optimization
-- Expected Queries: SELECT protocol_name, AVG(fee) AS avg_fee, SUM(fee) AS total_fees FROM transactions GROUP BY protocol_name
-- Critical Fields: fee, protocol_name, date

-- 6.1 Data Completeness: Check for NULL fee values
SELECT 
    'USE CASE 6.1: NULL fee check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE fee IS NULL;

-- 6.2 Data Accuracy: Verify fee is in reasonable range (Solana fees: 5000-1000000 lamports typically)
SELECT 
    'USE CASE 6.2: Fee range validation' AS validation,
    COUNT(*) AS invalid_fee_count,
    MIN(fee) AS min_fee,
    MAX(fee) AS max_fee,
    AVG(fee) AS avg_fee
FROM transactions
WHERE fee < 0 
    OR fee > 10000000; -- 0.01 SOL max (unusually high)

-- 6.3 Data Consistency: Verify fee distribution makes sense (most fees 5000-100000)
SELECT 
    'USE CASE 6.3: Fee distribution check' AS validation,
    CASE 
        WHEN fee < 5000 THEN 'too_low'
        WHEN fee BETWEEN 5000 AND 100000 THEN 'normal'
        WHEN fee BETWEEN 100000 AND 1000000 THEN 'high'
        ELSE 'very_high'
    END AS fee_category,
    COUNT(*) AS count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS percentage
FROM transactions
GROUP BY fee_category
ORDER BY count DESC;

-- 6.4 Query Performance: Test fee aggregation query
-- Expected: Should use indexes efficiently, < 1s for protocol-level aggregation
EXPLAIN PLAN
SELECT 
    protocol_name,
    COUNT(*) AS tx_count,
    AVG(fee) AS avg_fee,
    MIN(fee) AS min_fee,
    MAX(fee) AS max_fee,
    SUM(fee) AS total_fees
FROM transactions
WHERE date >= toDate('2024-12-01')
    AND protocol_name != ''
GROUP BY protocol_name
ORDER BY total_fees DESC
LIMIT 20;

-- 6.5 Data Accuracy: Verify fee correlates with compute_units (higher compute = higher fee typically)
SELECT 
    'USE CASE 6.5: Fee/compute correlation check' AS validation,
    AVG(fee) AS avg_fee,
    AVG(compute_units) AS avg_compute_units,
    AVG(fee / greatest(compute_units, 1)) AS fee_per_compute_unit
FROM transactions
WHERE compute_units > 0;

-- ============================================================================
-- USE CASE 7: Compute Unit Analysis
-- ============================================================================
-- Use Case: Monitor compute unit usage for performance optimization
-- Expected Queries: SELECT program_id, AVG(compute_units) AS avg_cu FROM transactions GROUP BY program_id
-- Critical Fields: compute_units, program_id, protocol_name

-- 7.1 Data Completeness: Check for NULL compute_units values
SELECT 
    'USE CASE 7.1: NULL compute_units check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE compute_units IS NULL;

-- 7.2 Data Accuracy: Verify compute_units is in reasonable range (Solana: 0-1.4M typically)
SELECT 
    'USE CASE 7.2: Compute units range validation' AS validation,
    COUNT(*) AS invalid_cu_count,
    MIN(compute_units) AS min_cu,
    MAX(compute_units) AS max_cu,
    AVG(compute_units) AS avg_cu
FROM transactions
WHERE compute_units < 0 
    OR compute_units > 2000000; -- 2M max (unusually high)

-- 7.3 Data Consistency: Verify compute_units distribution (most should be < 1.4M)
SELECT 
    'USE CASE 7.3: Compute units distribution check' AS validation,
    CASE 
        WHEN compute_units = 0 THEN 'zero'
        WHEN compute_units < 100000 THEN 'low'
        WHEN compute_units BETWEEN 100000 AND 1400000 THEN 'normal'
        WHEN compute_units BETWEEN 1400000 AND 2000000 THEN 'high'
        ELSE 'very_high'
    END AS cu_category,
    COUNT(*) AS count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS percentage
FROM transactions
GROUP BY cu_category
ORDER BY count DESC;

-- 7.4 Query Performance: Test compute unit aggregation query
-- Expected: Should be fast with proper indexes, < 1s for program-level aggregation
EXPLAIN PLAN
SELECT 
    program_id,
    COUNT(*) AS tx_count,
    AVG(compute_units) AS avg_compute_units,
    MIN(compute_units) AS min_cu,
    MAX(compute_units) AS max_cu,
    quantile(0.95)(compute_units) AS p95_compute_units
FROM transactions
WHERE date >= toDate('2024-12-01')
    AND program_id != ''
GROUP BY program_id
HAVING COUNT(*) > 100
ORDER BY avg_compute_units DESC
LIMIT 20;

-- 7.5 Data Accuracy: Verify compute_units > 0 for successful transactions (should have compute)
SELECT 
    'USE CASE 7.5: Zero compute units check' AS validation,
    COUNT(*) AS zero_cu_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS zero_cu_percentage
FROM transactions
WHERE compute_units = 0 AND success = 1;

-- ============================================================================
-- USE CASE 8: Failed Transaction Debugging
-- ============================================================================
-- Use Case: Analyze failed transactions for debugging and error tracking
-- Expected Queries: SELECT * FROM failed_transactions WHERE program_id = '...' ORDER BY slot DESC
-- Critical Fields: error_message, log_messages, program_id, slot

-- 8.1 Data Completeness: Check for NULL error_message or log_messages
SELECT 
    'USE CASE 8.1: NULL error/log fields check' AS validation,
    COUNT(*) AS null_error_count,
    COUNT(*) AS null_log_count
FROM failed_transactions
WHERE error_message IS NULL OR error_message = ''
    OR log_messages IS NULL OR log_messages = '';

-- 8.2 Data Accuracy: Verify error_message contains useful information (not empty)
SELECT 
    'USE CASE 8.2: Empty error message check' AS validation,
    COUNT(*) AS empty_error_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM failed_transactions) AS empty_error_percentage
FROM failed_transactions
WHERE error_message = '' OR length(error_message) < 5;

-- 8.3 Data Consistency: Verify failed_transactions don't appear in transactions table
SELECT 
    'USE CASE 8.3: Failed transaction cross-table check' AS validation,
    COUNT(*) AS failed_in_success_table
FROM failed_transactions f
INNER JOIN transactions t ON f.signature = t.signature;

-- 8.4 Query Performance: Test failed transaction lookup by program_id
-- Expected: Should use slot index efficiently, < 500ms for program-level queries
EXPLAIN PLAN
SELECT 
    program_id,
    COUNT(*) AS failed_count,
    COUNT(DISTINCT error_message) AS unique_errors
FROM failed_transactions
WHERE slot >= 377107390
    AND program_id != ''
GROUP BY program_id
ORDER BY failed_count DESC
LIMIT 20;

-- 8.5 Data Accuracy: Verify log_messages contains structured data (not just empty)
SELECT 
    'USE CASE 8.5: Log messages quality check' AS validation,
    COUNT(*) AS total_failed,
    COUNT(CASE WHEN log_messages != '' AND length(log_messages) > 10 THEN 1 END) AS has_logs,
    (COUNT(CASE WHEN log_messages != '' AND length(log_messages) > 10 THEN 1 END) * 100.0 / COUNT(*)) AS log_coverage_percentage
FROM failed_transactions;

-- ============================================================================
-- USE CASE 9: Slot Range Queries (Historical Data)
-- ============================================================================
-- Use Case: Query transactions within specific slot ranges for historical analysis
-- Expected Queries: SELECT * FROM transactions WHERE slot BETWEEN 377107390 AND 377117390
-- Critical Fields: slot, date, block_time

-- 9.1 Data Completeness: Check for NULL slot values
SELECT 
    'USE CASE 9.1: NULL slot check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE slot IS NULL;

-- 9.2 Data Accuracy: Verify slot is in reasonable range (Solana mainnet: ~100M+ slots as of 2024)
SELECT 
    'USE CASE 9.2: Slot range validation' AS validation,
    COUNT(*) AS invalid_slot_count,
    MIN(slot) AS min_slot,
    MAX(slot) AS max_slot
FROM transactions
WHERE slot < 100000000; -- Mainnet slots are > 100M

-- 9.3 Data Consistency: Verify slot ordering matches block_time ordering
SELECT 
    'USE CASE 9.3: Slot/block_time ordering consistency' AS validation,
    COUNT(*) AS inconsistent_ordering_count
FROM (
    SELECT 
        slot,
        block_time,
        LAG(block_time) OVER (ORDER BY slot) AS prev_block_time
    FROM transactions
    WHERE slot > 0 AND block_time > 0
)
WHERE prev_block_time IS NOT NULL 
    AND block_time < prev_block_time;

-- 9.4 Query Performance: Test slot range query with date partition
-- Expected: Should use partition pruning and slot ordering, < 1s for 10K slot range
EXPLAIN PLAN
SELECT 
    date,
    COUNT(*) AS tx_count,
    MIN(slot) AS min_slot,
    MAX(slot) AS max_slot,
    SUM(fee) AS total_fees
FROM transactions
WHERE slot BETWEEN 377107390 AND 377117390
GROUP BY date
ORDER BY date;

-- 9.5 Data Completeness: Check for slot gaps (missing slot ranges)
SELECT 
    'USE CASE 9.5: Slot coverage gaps' AS validation,
    min_slot,
    max_slot,
    expected_slots,
    actual_slots,
    expected_slots - actual_slots AS missing_slots,
    ((expected_slots - actual_slots) * 100.0 / expected_slots) AS gap_percentage
FROM (
    SELECT 
        MIN(slot) AS min_slot,
        MAX(slot) AS max_slot,
        (MAX(slot) - MIN(slot) + 1) AS expected_slots,
        COUNT(DISTINCT slot) AS actual_slots
    FROM transactions
    WHERE slot > 0
);

-- ============================================================================
-- USE CASE 10: Account Activity Analysis
-- ============================================================================
-- Use Case: Analyze transaction complexity by accounts_count for user activity tracking
-- Expected Queries: SELECT accounts_count, COUNT(*) AS tx_count FROM transactions GROUP BY accounts_count
-- Critical Fields: accounts_count, protocol_name, program_id

-- 10.1 Data Completeness: Check for NULL accounts_count values
SELECT 
    'USE CASE 10.1: NULL accounts_count check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE accounts_count IS NULL;

-- 10.2 Data Accuracy: Verify accounts_count is in reasonable range (Solana: 1-256 accounts per tx)
SELECT 
    'USE CASE 10.2: Accounts count range validation' AS validation,
    COUNT(*) AS invalid_count,
    MIN(accounts_count) AS min_accounts,
    MAX(accounts_count) AS max_accounts,
    AVG(accounts_count) AS avg_accounts
FROM transactions
WHERE accounts_count < 1 
    OR accounts_count > 256;

-- 10.3 Data Consistency: Verify accounts_count distribution (most txs have 2-10 accounts)
SELECT 
    'USE CASE 10.3: Accounts count distribution check' AS validation,
    CASE 
        WHEN accounts_count = 1 THEN 'single'
        WHEN accounts_count BETWEEN 2 AND 5 THEN 'small'
        WHEN accounts_count BETWEEN 6 AND 10 THEN 'medium'
        WHEN accounts_count BETWEEN 11 AND 20 THEN 'large'
        ELSE 'very_large'
    END AS account_category,
    COUNT(*) AS count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS percentage
FROM transactions
GROUP BY account_category
ORDER BY count DESC;

-- 10.4 Query Performance: Test accounts_count aggregation query
-- Expected: Should be fast, < 500ms for distribution analysis
EXPLAIN PLAN
SELECT 
    accounts_count,
    COUNT(*) AS tx_count,
    AVG(fee) AS avg_fee,
    AVG(compute_units) AS avg_compute_units
FROM transactions
WHERE date >= toDate('2024-12-01')
GROUP BY accounts_count
ORDER BY accounts_count;

-- 10.5 Data Accuracy: Verify accounts_count correlates with compute_units (more accounts = more compute typically)
SELECT 
    'USE CASE 10.5: Accounts/compute correlation check' AS validation,
    accounts_count,
    COUNT(*) AS tx_count,
    AVG(compute_units) AS avg_compute_units,
    AVG(fee) AS avg_fee
FROM transactions
WHERE compute_units > 0
GROUP BY accounts_count
HAVING COUNT(*) > 100
ORDER BY accounts_count;

-- ============================================================================
-- SUMMARY QUERIES: Overall Data Quality Metrics
-- ============================================================================

-- Overall table statistics
SELECT 
    'SUMMARY: Table row counts' AS metric,
    'transactions' AS table_name,
    COUNT(*) AS row_count,
    COUNT(DISTINCT signature) AS unique_signatures,
    COUNT(DISTINCT protocol_name) AS unique_protocols,
    COUNT(DISTINCT program_id) AS unique_programs,
    MIN(date) AS earliest_date,
    MAX(date) AS latest_date,
    MIN(slot) AS min_slot,
    MAX(slot) AS max_slot
FROM transactions
UNION ALL
SELECT 
    'SUMMARY: Table row counts' AS metric,
    'failed_transactions' AS table_name,
    COUNT(*) AS row_count,
    COUNT(DISTINCT signature) AS unique_signatures,
    COUNT(DISTINCT protocol_name) AS unique_protocols,
    COUNT(DISTINCT program_id) AS unique_programs,
    '' AS earliest_date,
    '' AS latest_date,
    MIN(slot) AS min_slot,
    MAX(slot) AS max_slot
FROM failed_transactions;

-- Data quality score (percentage of valid data)
SELECT 
    'SUMMARY: Data quality score' AS metric,
    (
        (SELECT COUNT(*) FROM transactions WHERE signature != '' AND protocol_name != '' AND date IS NOT NULL AND slot > 0) * 100.0 / 
        (SELECT COUNT(*) FROM transactions)
    ) AS transactions_quality_score,
    (
        (SELECT COUNT(*) FROM failed_transactions WHERE signature != '' AND error_message != '' AND log_messages != '') * 100.0 / 
        (SELECT COUNT(*) FROM failed_transactions)
    ) AS failed_transactions_quality_score;

-- Index usage validation
SELECT 
    'SUMMARY: Index validation' AS metric,
    name AS index_name,
    type AS index_type,
    expr AS index_expression
FROM system.data_skipping_indices
WHERE database = currentDatabase()
    AND table = 'transactions'
ORDER BY name;

-- ============================================================================
-- NOTES ON VALIDATION RESULTS
-- ============================================================================
-- 
-- Expected Results for Instruction-Level Data Model:
-- 
-- 1. USE CASE 3.3 (Signature Distribution):
--    - Duplicate signatures are EXPECTED (one transaction = multiple instructions)
--    - avg_instructions_per_signature should be > 1.0
--    - This is NOT a data quality issue
--
-- 2. USE CASE 3.5 (Cross-Table Distribution):
--    - Signatures appearing in both tables is EXPECTED
--    - Occurs when transaction has mixed instruction results
--    - This is NOT a data quality issue
--
-- 3. USE CASE 4.3 (Date/Block_Time Consistency):
--    - Should be 0 since date is now MATERIALIZED as toDate(block_time)
--    - If non-zero, indicates an issue with the MATERIALIZED column calculation
--
-- 4. All other validations should pass with 0 errors or very low error rates
--
-- ============================================================================

