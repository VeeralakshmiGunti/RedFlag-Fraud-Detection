USE redflag;

-- =====================================================
-- P1: Velocity Fraud
-- Flag users making 30+ transactions on the same day.
-- =====================================================

SELECT
    user_id,
    DATE(txn_time) AS txn_date,
    COUNT(*) AS transaction_count
FROM transactions
GROUP BY user_id, DATE(txn_time)
HAVING COUNT(*) >= 30
ORDER BY transaction_count DESC;
-- Finding: 48 suspicious user-days detected.

-- =====================================================
-- P2: Round-Amount Clustering
-- Detect users making 15 or more transactions
-- using common round transaction amounts.
-- =====================================================

SELECT
    user_id,
    COUNT(*) AS round_amount_transactions
FROM transactions
WHERE amount IN (100, 200, 500, 1000, 2000, 5000, 10000)
GROUP BY user_id
HAVING COUNT(*) >= 15
ORDER BY round_amount_transactions DESC;
-- Finding: 25 suspicious users detected.

-- =====================================================
-- P3: Card Testing
-- Detect users making 30 or more low-value transactions
-- (below ₹10) on the same calendar day.
-- =====================================================

SELECT
    user_id,
    DATE(txn_time) AS txn_date,
    COUNT(*) AS low_value_transactions
FROM transactions
WHERE amount < 10
GROUP BY user_id, DATE(txn_time)
HAVING COUNT(*) >= 30
ORDER BY low_value_transactions DESC;
-- Finding: 20 suspicious user-days detected.

-- =====================================================
-- P4: Failed-Then-Succeeded
-- Detect users with 20 or more failed transactions,
-- indicating repeated payment attempts.
-- =====================================================

SELECT
    user_id,
    COUNT(*) AS failed_transactions
FROM transactions
WHERE status = 'FAILED'
GROUP BY user_id
HAVING COUNT(*) >= 20
ORDER BY failed_transactions DESC;
-- Finding: 25 suspicious users detected.

-- =====================================================
-- P5: Odd-Hour Concentration
-- Detect users with 30+ total transactions where
-- at least 80% occurred during the 2 AM to 4 AM window.
-- =====================================================

SELECT
    user_id,
    COUNT(*) AS total_transactions,
    SUM(
        CASE
            WHEN HOUR(txn_time) BETWEEN 2 AND 4 THEN 1
            ELSE 0
        END
    ) AS odd_hour_transactions,
    ROUND(
        100.0 * SUM(
            CASE
                WHEN HOUR(txn_time) BETWEEN 2 AND 4 THEN 1
                ELSE 0
            END
        ) / COUNT(*),
        2
    ) AS odd_hour_percentage
FROM transactions
GROUP BY user_id
HAVING COUNT(*) >= 30
   AND SUM(
        CASE
            WHEN HOUR(txn_time) BETWEEN 2 AND 4 THEN 1
            ELSE 0
        END
   ) / COUNT(*) >= 0.80
ORDER BY odd_hour_percentage DESC, total_transactions DESC;
-- Finding: 20 suspicious users detected.

-- =====================================================
-- P6: Mule Accounts
-- Detect users receiving 8 or more CREDIT transactions.
-- Frequent credits may indicate potential mule-account
-- activity.
-- =====================================================

SELECT
    user_id,
    COUNT(*) AS credit_transactions
FROM transactions
WHERE txn_type = 'CREDIT'
GROUP BY user_id
HAVING COUNT(*) >= 8
ORDER BY credit_transactions DESC;
-- Finding: 30 suspicious users detected.


-- =====================================================
-- P7: Refund Abuse
-- Detect users with 20 or more total transactions
-- where refunds account for more than 40% of activity.
-- =====================================================

SELECT
    user_id,
    COUNT(*) AS total_transactions,
    SUM(
        CASE
            WHEN txn_type = 'REFUND' THEN 1
            ELSE 0
        END
    ) AS refund_transactions,
    ROUND(
        100.0 * SUM(
            CASE
                WHEN txn_type = 'REFUND' THEN 1
                ELSE 0
            END
        ) / COUNT(*),
        2
    ) AS refund_percentage
FROM transactions
GROUP BY user_id
HAVING COUNT(*) >= 20
   AND SUM(
        CASE
            WHEN txn_type = 'REFUND' THEN 1
            ELSE 0
        END
   ) / COUNT(*) > 0.40
ORDER BY refund_percentage DESC;
-- Finding: 24 suspicious users detected.

-- =====================================================
-- P8: Merchant Collusion
-- Detect merchants where the top 5 users by transaction
-- volume account for more than 60% of the merchant's
-- total transaction value.
-- =====================================================

WITH user_merchant_volume AS (
    SELECT
        merchant_id,
        user_id,
        SUM(amount) AS user_total_amount
    FROM transactions
    GROUP BY merchant_id, user_id
),
ranked_users AS (
    SELECT
        merchant_id,
        user_id,
        user_total_amount,
        ROW_NUMBER() OVER (
            PARTITION BY merchant_id
            ORDER BY user_total_amount DESC
        ) AS user_rank
    FROM user_merchant_volume
),
merchant_totals AS (
    SELECT
        merchant_id,
        SUM(amount) AS merchant_total_amount
    FROM transactions
    GROUP BY merchant_id
)
SELECT
    r.merchant_id,
    ROUND(
        100.0 * SUM(r.user_total_amount)
        / m.merchant_total_amount,
        2
    ) AS top5_percentage
FROM ranked_users r
JOIN merchant_totals m
    ON r.merchant_id = m.merchant_id
WHERE r.user_rank <= 5
GROUP BY r.merchant_id, m.merchant_total_amount
HAVING SUM(r.user_total_amount)
       / m.merchant_total_amount > 0.60
ORDER BY top5_percentage DESC;
-- Finding: 15 suspicious merchants detected.

-- =====================================================
-- P9: Just-Under-Threshold
-- Detect users making 10 or more transactions
-- of exactly ₹9,999, just below a common threshold.
-- =====================================================

SELECT
    user_id,
    COUNT(*) AS threshold_transactions
FROM transactions
WHERE amount = 9999
GROUP BY user_id
HAVING COUNT(*) >= 10
ORDER BY threshold_transactions DESC;
-- Finding: 20 suspicious users detected.

-- =====================================================
-- P10: Dormant-Then-Active
-- Detect users who had a 90+ day gap between
-- consecutive transactions and then became highly active
-- with 15 or more transactions after the gap.
-- =====================================================

WITH transaction_gaps AS (
    SELECT
        user_id,
        txn_time,
        LAG(txn_time) OVER (
            PARTITION BY user_id
            ORDER BY txn_time
        ) AS previous_txn_time
    FROM transactions
),
dormant_periods AS (
    SELECT
        user_id,
        txn_time AS active_start
    FROM transaction_gaps
    WHERE previous_txn_time IS NOT NULL
      AND TIMESTAMPDIFF(
            DAY,
            previous_txn_time,
            txn_time
          ) >= 90
)
SELECT
    d.user_id,
    d.active_start,
    COUNT(t.txn_id) AS transactions_after_gap
FROM dormant_periods d
JOIN transactions t
    ON t.user_id = d.user_id
   AND t.txn_time >= d.active_start
GROUP BY d.user_id, d.active_start
HAVING COUNT(t.txn_id) >= 15
ORDER BY transactions_after_gap DESC;
-- Finding: 26 suspicious users detected.

-- =====================================================
-- P11: Velocity Spike
-- Detect users whose peak monthly transaction count
-- is at least 5 times their average monthly count,
-- with a peak of at least 20 transactions.
-- =====================================================

WITH monthly_counts AS (
    SELECT
        user_id,
        DATE_FORMAT(txn_time, '%Y-%m') AS transaction_month,
        COUNT(*) AS monthly_transactions
    FROM transactions
    GROUP BY user_id, DATE_FORMAT(txn_time, '%Y-%m')
),
user_stats AS (
    SELECT
        user_id,
        MAX(monthly_transactions) AS peak_monthly_transactions,
        SUM(monthly_transactions) / 6.0 AS average_monthly_transactions
    FROM monthly_counts
    GROUP BY user_id
)
SELECT
    user_id,
    peak_monthly_transactions,
    ROUND(average_monthly_transactions, 2) AS average_monthly_transactions,
    ROUND(
        peak_monthly_transactions / average_monthly_transactions,
        2
    ) AS spike_ratio
FROM user_stats
WHERE peak_monthly_transactions >= 20
  AND peak_monthly_transactions >= 5 * average_monthly_transactions
ORDER BY spike_ratio DESC;
-- Finding: 66 suspicious users detected.

-- =====================================================
-- P12: Geographic Impossibility
-- Detect users who made consecutive transactions
-- in different cities within 60 minutes.
-- =====================================================

WITH transaction_sequence AS (
    SELECT
        user_id,
        txn_time,
        city,
        LAG(txn_time) OVER (
            PARTITION BY user_id
            ORDER BY txn_time
        ) AS previous_txn_time,
        LAG(city) OVER (
            PARTITION BY user_id
            ORDER BY txn_time
        ) AS previous_city
    FROM transactions
)
SELECT
    user_id,
    previous_city,
    city AS current_city,
    previous_txn_time,
    txn_time AS current_txn_time,
    TIMESTAMPDIFF(
        MINUTE,
        previous_txn_time,
        txn_time
    ) AS minutes_between
FROM transaction_sequence
WHERE previous_city IS NOT NULL
  AND city <> previous_city
  AND TIMESTAMPDIFF(
        MINUTE,
        previous_txn_time,
        txn_time
      ) <= 60
ORDER BY minutes_between ASC;
-- Finding: 15 suspicious users detected.