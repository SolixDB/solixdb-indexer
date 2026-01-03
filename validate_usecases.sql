-- This file was AI generated
-- SolixDB Data Quality Validation Queries
--
-- Instruction-Level Storage: One transaction = multiple instructions (signatures not unique)
-- MATERIALIZED Columns: date and hour are auto-calculated from block_time

-- USE CASE 1: Protocol Analytics

-- 1.1 NULL protocol_name check
SELECT 
    'USE CASE 1.1: NULL protocol_name check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE protocol_name IS NULL OR protocol_name = '';

-- 1.2 Invalid protocol_name values
SELECT 
    'USE CASE 1.2: Invalid protocol_name values' AS validation,
    protocol_name,
    COUNT(*) AS count
FROM transactions
WHERE protocol_name IN ('unknown', 'Unknown', 'UNKNOWN', '', 'N/A', 'null')
GROUP BY protocol_name
ORDER BY count DESC;

-- 1.3 Protocol name format validation
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

-- 1.4 Query performance test (protocol_name filter)
EXPLAIN PLAN
SELECT 
    protocol_name,
    COUNT(*) AS tx_count,
    SUM(fee) AS total_fees,
    AVG(compute_units) AS avg_compute_units
FROM transactions
WHERE protocol_name = 'Jupiter'
    AND toDate(block_time) >= toDate('2024-01-01')
GROUP BY protocol_name;

-- 1.5 Date validity check
SELECT 
    'USE CASE 1.5: Date validity check' AS validation,
    COUNT(*) AS invalid_date_count
FROM transactions
WHERE toDate(block_time) IS NULL 
    OR toDate(block_time) < toDate('2020-01-01')  -- Before Solana mainnet
    OR toDate(block_time) > today() + 1;  -- Not in future

-- 1.6 NULL instruction_type check
SELECT 
    'USE CASE 1.6: NULL instruction_type check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE instruction_type IS NULL OR instruction_type = '';

-- 1.7 Invalid instruction_type values
SELECT 
    'USE CASE 1.7: Invalid instruction_type values' AS validation,
    instruction_type,
    COUNT(*) AS count
FROM transactions
WHERE instruction_type IN ('unknown', 'Unknown', 'UNKNOWN', '', 'N/A', 'null')
GROUP BY instruction_type
ORDER BY count DESC
LIMIT 20;

-- 1.8 Instruction type format validation
SELECT 
    'USE CASE 1.8: Instruction type format validation' AS validation,
    COUNT(*) AS invalid_format_count
FROM transactions
WHERE instruction_type != '' 
    AND (
        instruction_type LIKE '%\n%' 
        OR instruction_type LIKE '%\r%'
        OR instruction_type LIKE '%\t%'
        OR length(instruction_type) > 100
    );

-- 1.9 Instruction type by protocol distribution
SELECT 
    'USE CASE 1.9: Instruction type by protocol distribution' AS validation,
    protocol_name,
    instruction_type,
    COUNT(*) AS count
FROM transactions
WHERE protocol_name != '' AND instruction_type != ''
GROUP BY protocol_name, instruction_type
HAVING COUNT(*) > 100
ORDER BY protocol_name, count DESC
LIMIT 50;

-- USE CASE 2: Program-Level Analytics

-- 2.1 NULL program_id check
SELECT 
    'USE CASE 2.1: NULL program_id check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE program_id IS NULL OR program_id = '';

-- 2.2 Invalid program_id format
SELECT 
    'USE CASE 2.2: Invalid program_id format' AS validation,
    COUNT(*) AS invalid_format_count
FROM transactions
WHERE program_id != ''
    AND (length(program_id) < 32 OR length(program_id) > 44);

-- 2.3 Program ID consistency check
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

-- 2.4 Query performance test (program_id filter)
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

-- 2.5 Block time range validation
SELECT 
    'USE CASE 2.5: Block time range validation' AS validation,
    COUNT(*) AS invalid_block_time_count
FROM transactions
WHERE block_time = 0 
    OR block_time > toUnixTimestamp(now())
    OR block_time < 1609459200; -- Jan 1, 2021 (Solana mainnet launch)

-- USE CASE 3: Transaction Signature Lookup

-- 3.1 NULL signature check
SELECT 
    'USE CASE 3.1: NULL signature check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE signature IS NULL OR signature = '';

-- 3.2 Invalid signature format
SELECT 
    'USE CASE 3.2: Invalid signature format' AS validation,
    COUNT(*) AS invalid_format_count
FROM transactions
WHERE signature != ''
    AND (length(signature) < 80 OR length(signature) > 100);

-- 3.3 Signature distribution (duplicates expected for instruction-level model)
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

-- 3.4 Query performance test (signature lookup)
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

-- 3.5 Signature cross-table distribution (expected for instruction-level model)
SELECT 
    'USE CASE 3.5: Signature cross-table distribution (instruction-level model)' AS validation,
    COUNT(DISTINCT t.signature) AS signatures_in_both_tables,
    COUNT(DISTINCT t.signature) * 100.0 / greatest(COUNT(DISTINCT t.signature), 1) AS percentage_with_mixed_results,
    COUNT(*) AS total_instruction_rows_with_mixed_results
FROM transactions t
INNER JOIN failed_transactions f ON t.signature = f.signature;

-- USE CASE 4: Time-Based Analytics

-- 4.1 NULL date/hour check
SELECT 
    'USE CASE 4.1: NULL date/hour check' AS validation,
    COUNT(*) AS null_date_count,
    COUNT(*) AS null_hour_count
FROM transactions
WHERE block_time = 0 OR block_time IS NULL OR hour IS NULL;

-- 4.2 Invalid hour range
SELECT 
    'USE CASE 4.2: Invalid hour range' AS validation,
    hour,
    COUNT(*) AS count
FROM transactions
WHERE hour > 23 OR hour < 0
GROUP BY hour;

-- 4.3 Date/block_time consistency
SELECT 
    'USE CASE 4.3: Date/block_time consistency' AS validation,
    COUNT(*) AS inconsistent_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions WHERE block_time > 0) AS inconsistency_percentage
FROM transactions
WHERE toDate(block_time) != toDate(block_time)
    AND block_time > 0;

-- 4.4 Query performance test (date/hour filter)
EXPLAIN PLAN
SELECT 
    toDate(block_time) AS date,
    hour,
    COUNT(*) AS tx_count,
    SUM(fee) AS total_fees,
    AVG(compute_units) AS avg_compute_units
FROM transactions
WHERE toDate(block_time) = toDate('2024-12-30')
    AND hour BETWEEN 10 AND 14
GROUP BY toDate(block_time), hour
ORDER BY hour;

-- 4.5 Date coverage gaps
SELECT 
    'USE CASE 4.5: Date coverage gaps' AS validation,
    min_date,
    max_date,
    expected_days,
    actual_days,
    expected_days - actual_days AS missing_days
FROM (
    SELECT 
        min(toDate(block_time)) AS min_date,
        max(toDate(block_time)) AS max_date,
        dateDiff('day', min(toDate(block_time)), max(toDate(block_time))) + 1 AS expected_days,
        COUNT(DISTINCT toDate(block_time)) AS actual_days
    FROM transactions
    WHERE block_time > 0
);

-- USE CASE 5: Success Rate Monitoring

-- 5.1 NULL success check
SELECT 
    'USE CASE 5.1: NULL success check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE success IS NULL;

-- 5.2 Invalid success values
SELECT 
    'USE CASE 5.2: Invalid success values' AS validation,
    success,
    COUNT(*) AS count
FROM transactions
WHERE success NOT IN (0, 1)
GROUP BY success;

-- 5.3 Success rate validation
SELECT 
    'USE CASE 5.3: Success rate validation' AS validation,
    COUNT(*) AS total_txs,
    SUM(success) AS successful_txs,
    COUNT(*) - SUM(success) AS failed_txs,
    (SUM(success) * 100.0 / COUNT(*)) AS success_rate_percentage
FROM transactions;

-- 5.4 Query performance test (success rate aggregation)
EXPLAIN PLAN
SELECT 
    protocol_name,
    COUNT(*) AS total_txs,
    SUM(success) AS successful_txs,
    (SUM(success) * 100.0 / COUNT(*)) AS success_rate
FROM transactions
WHERE toDate(block_time) >= toDate('2024-12-01')
GROUP BY protocol_name
ORDER BY total_txs DESC
LIMIT 20;

-- 5.5 Protocol success rate comparison
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

-- USE CASE 6: Fee Analysis

-- 6.1 NULL fee check
SELECT 
    'USE CASE 6.1: NULL fee check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE fee IS NULL;

-- 6.2 Fee range validation
SELECT 
    'USE CASE 6.2: Fee range validation' AS validation,
    COUNT(*) AS invalid_fee_count,
    MIN(fee) AS min_fee,
    MAX(fee) AS max_fee,
    AVG(fee) AS avg_fee
FROM transactions
WHERE fee < 0 
    OR fee > 10000000; -- 0.01 SOL max (unusually high)

-- 6.3 Fee distribution check
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

-- 6.4 Query performance test (fee aggregation)
EXPLAIN PLAN
SELECT 
    protocol_name,
    COUNT(*) AS tx_count,
    AVG(fee) AS avg_fee,
    MIN(fee) AS min_fee,
    MAX(fee) AS max_fee,
    SUM(fee) AS total_fees
FROM transactions
WHERE toDate(block_time) >= toDate('2024-12-01')
    AND protocol_name != ''
GROUP BY protocol_name
ORDER BY total_fees DESC
LIMIT 20;

-- 6.5 Fee/compute correlation check
SELECT 
    'USE CASE 6.5: Fee/compute correlation check' AS validation,
    AVG(fee) AS avg_fee,
    AVG(compute_units) AS avg_compute_units,
    AVG(fee / greatest(compute_units, 1)) AS fee_per_compute_unit
FROM transactions
WHERE compute_units > 0;

-- USE CASE 7: Compute Unit Analysis

-- 7.1 NULL compute_units check
SELECT 
    'USE CASE 7.1: NULL compute_units check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE compute_units IS NULL;

-- 7.2 Compute units range validation
SELECT 
    'USE CASE 7.2: Compute units range validation' AS validation,
    COUNT(*) AS invalid_cu_count,
    MIN(compute_units) AS min_cu,
    MAX(compute_units) AS max_cu,
    AVG(compute_units) AS avg_cu
FROM transactions
WHERE compute_units < 0 
    OR compute_units > 2000000; -- 2M max (unusually high)

-- 7.3 Compute units distribution check
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

-- 7.4 Query performance test (compute unit aggregation)
EXPLAIN PLAN
SELECT 
    program_id,
    COUNT(*) AS tx_count,
    AVG(compute_units) AS avg_compute_units,
    MIN(compute_units) AS min_cu,
    MAX(compute_units) AS max_cu,
    quantile(0.95)(compute_units) AS p95_compute_units
FROM transactions
WHERE toDate(block_time) >= toDate('2024-12-01')
    AND program_id != ''
GROUP BY program_id
HAVING COUNT(*) > 100
ORDER BY avg_compute_units DESC
LIMIT 20;

-- 7.5 Zero compute units check
SELECT 
    'USE CASE 7.5: Zero compute units check' AS validation,
    COUNT(*) AS zero_cu_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS zero_cu_percentage
FROM transactions
WHERE compute_units = 0 AND success = 1;

-- USE CASE 8: Failed Transaction Debugging

-- 8.1 NULL error/log fields check
SELECT 
    'USE CASE 8.1: NULL error/log fields check' AS validation,
    COUNT(*) AS null_error_count,
    COUNT(*) AS null_log_count
FROM failed_transactions
WHERE error_message IS NULL OR error_message = ''
    OR log_messages IS NULL OR log_messages = '';

-- 8.2 Empty error message check
SELECT 
    'USE CASE 8.2: Empty error message check' AS validation,
    COUNT(*) AS empty_error_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM failed_transactions) AS empty_error_percentage
FROM failed_transactions
WHERE error_message = '' OR length(error_message) < 5;

-- 8.3 Failed transaction cross-table check
SELECT 
    'USE CASE 8.3: Failed transaction cross-table check' AS validation,
    COUNT(*) AS failed_in_success_table
FROM failed_transactions f
INNER JOIN transactions t ON f.signature = t.signature;

-- 8.4 Query performance test (failed transaction lookup)
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

-- 8.5 Log messages quality check
SELECT 
    'USE CASE 8.5: Log messages quality check' AS validation,
    COUNT(*) AS total_failed,
    COUNT(CASE WHEN log_messages != '' AND length(log_messages) > 10 THEN 1 END) AS has_logs,
    (COUNT(CASE WHEN log_messages != '' AND length(log_messages) > 10 THEN 1 END) * 100.0 / COUNT(*)) AS log_coverage_percentage
FROM failed_transactions;

-- USE CASE 9: Slot Range Queries

-- 9.1 NULL slot check
SELECT 
    'USE CASE 9.1: NULL slot check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE slot IS NULL;

-- 9.2 Slot range validation
SELECT 
    'USE CASE 9.2: Slot range validation' AS validation,
    COUNT(*) AS invalid_slot_count,
    MIN(slot) AS min_slot,
    MAX(slot) AS max_slot
FROM transactions
WHERE slot < 100000000; -- Mainnet slots are > 100M

-- 9.3 Slot/block_time ordering consistency
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

-- 9.4 Query performance test (slot range query)
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

-- 9.5 Slot coverage gaps
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

-- USE CASE 10: Account Activity Analysis

-- 10.1 NULL accounts_count check
SELECT 
    'USE CASE 10.1: NULL accounts_count check' AS validation,
    COUNT(*) AS null_count,
    COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transactions) AS null_percentage
FROM transactions
WHERE accounts_count IS NULL;

-- 10.2 Accounts count range validation
SELECT 
    'USE CASE 10.2: Accounts count range validation' AS validation,
    COUNT(*) AS invalid_count,
    MIN(accounts_count) AS min_accounts,
    MAX(accounts_count) AS max_accounts,
    AVG(accounts_count) AS avg_accounts
FROM transactions
WHERE accounts_count < 1 
    OR accounts_count > 256;

-- 10.3 Accounts count distribution check
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

-- 10.4 Query performance test (accounts_count aggregation)
EXPLAIN PLAN
SELECT 
    accounts_count,
    COUNT(*) AS tx_count,
    AVG(fee) AS avg_fee,
    AVG(compute_units) AS avg_compute_units
FROM transactions
WHERE toDate(block_time) >= toDate('2024-12-01')
GROUP BY accounts_count
ORDER BY accounts_count;

-- 10.5 Accounts/compute correlation check
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

-- SUMMARY: Overall Data Quality Metrics

-- Table statistics
SELECT 
    'SUMMARY: Table row counts' AS metric,
    'transactions' AS table_name,
    COUNT(*) AS row_count,
    COUNT(DISTINCT signature) AS unique_signatures,
    COUNT(DISTINCT protocol_name) AS unique_protocols,
    COUNT(DISTINCT program_id) AS unique_programs,
    COUNT(DISTINCT instruction_type) AS unique_instruction_types,
    toString(MIN(toDate(block_time))) AS earliest_date,
    toString(MAX(toDate(block_time))) AS latest_date,
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
    0 AS unique_instruction_types,  -- failed_transactions doesn't have instruction_type
    '' AS earliest_date,
    '' AS latest_date,
    MIN(slot) AS min_slot,
    MAX(slot) AS max_slot
FROM failed_transactions;

-- Data quality score
SELECT 
    'SUMMARY: Data quality score' AS metric,
    (
        (SELECT COUNT(*) FROM transactions WHERE signature != '' AND protocol_name != '' AND instruction_type != '' AND block_time > 0 AND slot > 0) * 100.0 / 
        (SELECT COUNT(*) FROM transactions)
    ) AS transactions_quality_score,
    (
        (SELECT COUNT(*) FROM failed_transactions WHERE signature != '' AND error_message != '' AND log_messages != '') * 100.0 / 
        (SELECT COUNT(*) FROM failed_transactions)
    ) AS failed_transactions_quality_score;

-- Index validation
SELECT 
    'SUMMARY: Index validation' AS metric,
    name AS index_name,
    type AS index_type,
    expr AS index_expression
FROM system.data_skipping_indices
WHERE database = currentDatabase()
    AND table = 'transactions'
ORDER BY name;

-- NOTES: 3.3 & 3.5 - Duplicate signatures expected (instruction-level model)
--        4.3 - Should be 0 (date is MATERIALIZED from block_time)

