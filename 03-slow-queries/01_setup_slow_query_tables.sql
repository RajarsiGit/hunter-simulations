-- =============================================================================
-- 01_setup_slow_query_tables.sql
-- Slow Queries DRILL — shared setup for scripts 02-09
-- SysCloud DAL Team
--
-- Creates three intentionally UNINDEXED (beyond primary key) tables and seeds
-- them with realistic row counts via generate_series, so the drills in this
-- folder can reproduce real planner behavior (seq scans, bad estimates,
-- function-on-column plan misses) rather than just describing it.
--
-- ⚠️  NON-PRODUCTION USE ONLY. Run against a disposable/drill database.
-- Requires PGHOST/PGPORT/PGUSER/PGDATABASE to be set (via .env + `set -a;
-- source .env; set +a` before invoking psql, or exported directly).
--
-- Usage:
--   psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE \
--        -f 01_setup_slow_query_tables.sql
--
-- FAST SIZING: seeds ~550k rows total — sized so setup finishes in seconds
-- and every downstream drill script (02-07) completes in <=20s by default,
-- while each table still clears the hunter's n_live_tup>100k pre-filter
-- (queries/slow-queries/slow-queries-seq-scans.sql; slow-queries-stale-stats.sql)
-- with margin. This intentionally trades away the wide multi-minute hunter-
-- poll observation window the original ~27M-row sizing gave; not tuned for
-- live hunter-detection reliability, only for a quick local drill run.
-- =============================================================================

\timing on

-- -----------------------------------------------------------------------------
-- slowq_orders — Scenario source for missing-index scans, offset pagination,
-- stale statistics, and the diagnostic sweep. Deliberately NO index on
-- status/created_at/customer_id beyond the primary key.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS slowq_orders CASCADE;
CREATE TABLE slowq_orders (
    id          bigserial PRIMARY KEY,
    customer_id int         NOT NULL,
    status      text        NOT NULL,
    amount      numeric(12,2) NOT NULL,
    created_at  timestamptz NOT NULL
);

INSERT INTO slowq_orders (customer_id, status, amount, created_at)
SELECT
    (random() * 49999)::int + 1,
    CASE
        WHEN r < 0.90 THEN 'paid'
        WHEN r < 0.95 THEN 'processing'
        ELSE 'failed'
    END,
    round((random() * 500 + 1)::numeric, 2),
    now() - (random() * interval '180 days')
FROM (
    SELECT random() AS r
    FROM generate_series(1, 200000)
) s;

ANALYZE slowq_orders;

-- -----------------------------------------------------------------------------
-- slowq_customers — Scenario source for function-on-indexed-column drills.
-- Sized well above the slow-queries hunter's n_live_tup > 100k pre-filter so
-- seq_scan_tables can actually fire for this table too (at 50k rows it
-- couldn't).
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS slowq_customers CASCADE;
CREATE TABLE slowq_customers (
    id         bigserial PRIMARY KEY,
    email      text NOT NULL,
    status     text NOT NULL
);

INSERT INTO slowq_customers (email, status)
SELECT
    'user' || g || '@example.com',
    CASE WHEN random() < 0.8 THEN 'active' ELSE 'inactive' END
FROM generate_series(1, 150000) AS g;

ANALYZE slowq_customers;

-- -----------------------------------------------------------------------------
-- slowq_json_events — Scenario source for JSON processing CPU-spike drill.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS slowq_json_events CASCADE;
CREATE TABLE slowq_json_events (
    id   bigserial PRIMARY KEY,
    data jsonb NOT NULL
);

INSERT INTO slowq_json_events (data)
SELECT jsonb_build_object(
    'tenant_id', (random() * 1000)::int,
    'status', substr(md5(random()::text), 1, 8),
    'payload', repeat(md5(random()::text), 10)
)
FROM generate_series(1, 200000);

ANALYZE slowq_json_events;

\timing off

SELECT 'slowq_orders' AS table_name, count(*) AS row_count FROM slowq_orders
UNION ALL
SELECT 'slowq_customers', count(*) FROM slowq_customers
UNION ALL
SELECT 'slowq_json_events', count(*) FROM slowq_json_events;

\echo 'Setup complete. No indexes exist beyond primary keys — that is intentional;'
\echo 'these drills only demonstrate the problem, they never fix it.'
