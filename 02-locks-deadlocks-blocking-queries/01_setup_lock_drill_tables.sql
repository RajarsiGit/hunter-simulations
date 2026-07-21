-- =============================================================================
-- 01_setup_lock_drill_tables.sql
-- Locks & Deadlocks DRILL — Test Table Setup
-- SysCloud DAL Team
--
-- Creates all tables and seed data required by the lock/deadlock drill scripts
-- in this folder. Run once on the drill/test instance before running any
-- simulator. Safe to re-run: uses CREATE TABLE IF NOT EXISTS + TRUNCATE.
--
-- psql does not read .env itself — export the vars first, e.g.:
--   set -a; source .env; set +a
--   psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" \
--     -f 01_setup_lock_drill_tables.sql
-- =============================================================================




-- ---------------------------------------------------------------------------
-- 1. Accounts table
--    Used by: row-lock blocking (02), classic deadlock (03),
--             AccessExclusiveLock (04), DDL-blocking-DML (05)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lock_test_accounts (
    id      integer PRIMARY KEY,
    name    text    NOT NULL,
    status  text    NULL,
    balance numeric NOT NULL DEFAULT 0
);

TRUNCATE lock_test_accounts;

INSERT INTO lock_test_accounts (id, name, balance) VALUES
    (1, 'Alice',   1000.00),
    (2, 'Bob',     2000.00),
    (3, 'Charlie', 1500.00),
    (4, 'Diana',    500.00),
    (5, 'Eve',     3000.00);



-- ---------------------------------------------------------------------------
-- 2. Parent / child tables
--    Used by: FK contention drill (13)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lock_test_parent (
    id   integer PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE IF NOT EXISTS lock_test_child (
    id        integer PRIMARY KEY,
    parent_id integer NOT NULL REFERENCES lock_test_parent(id),
    payload   text
);

-- Index on FK column — illustrates best practice (missing FK indexes are a
-- common real-world cause of extra contention/scan time on parent DELETE/UPDATE)
CREATE INDEX IF NOT EXISTS idx_lock_test_child_parent_id
    ON lock_test_child(parent_id);

TRUNCATE lock_test_child;
TRUNCATE lock_test_parent CASCADE;

-- Parent Gamma (id=3) is intentionally left WITHOUT any pre-seeded child rows —
-- the FK contention drill (13) needs a parent whose only referencing row is the
-- one IT inserts mid-drill. Parent Alpha/Beta (id=1/2) already have committed
-- child rows below; a DELETE against either fails on THOSE rows immediately
-- (a plain FK violation) without ever needing to wait on anything, so a drill
-- using id=1/2 never produces a genuine lock wait for the hunter to observe.
INSERT INTO lock_test_parent (id, name)
VALUES (1, 'Parent Alpha'), (2, 'Parent Beta'), (3, 'Parent Gamma');

INSERT INTO lock_test_child (id, parent_id, payload) VALUES
    (1, 1, 'child-a1'),
    (2, 1, 'child-a2'),
    (3, 2, 'child-b1');



-- ---------------------------------------------------------------------------
-- 3. User credits table
--    Used by: multi-module deadlock (07)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lock_test_credits (
    user_id integer PRIMARY KEY,
    credits numeric NOT NULL DEFAULT 0
);

TRUNCATE lock_test_credits;

INSERT INTO lock_test_credits (user_id, credits) VALUES
    (1, 500.00),
    (2, 750.00),
    (3, 200.00);



-- ---------------------------------------------------------------------------
-- 4. Job queue table
--    Used by: SKIP LOCKED demo (17) and connection-spike simulation (16)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lock_test_job_queue (
    id         serial       PRIMARY KEY,
    status     text         NOT NULL DEFAULT 'PENDING',
    payload    text,
    created_at timestamptz  NOT NULL DEFAULT now()
);

TRUNCATE lock_test_job_queue;

INSERT INTO lock_test_job_queue (status, payload)
SELECT 'PENDING', 'job-' || i
FROM   generate_series(1, 20) AS i;



-- ---------------------------------------------------------------------------
-- 5. Materialized view base table + MVW
--    Used by: MVW refresh locking (08)
--    Unique index on lock_test_mvw is required for REFRESH CONCURRENTLY.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lock_test_mvw_base (
    id         integer      PRIMARY KEY,
    category   text         NOT NULL,
    amount     numeric      NOT NULL,
    created_at timestamptz  NOT NULL DEFAULT now()
);

TRUNCATE lock_test_mvw_base;

INSERT INTO lock_test_mvw_base (id, category, amount)
SELECT i,
       'cat-' || (i % 5 + 1),
       round((random() * 1000)::numeric, 2)
FROM   generate_series(1, 100) AS i;

DROP MATERIALIZED VIEW IF EXISTS lock_test_mvw;

CREATE MATERIALIZED VIEW lock_test_mvw AS
SELECT   category,
         SUM(amount)  AS total_amount,
         COUNT(*)     AS row_count
FROM     lock_test_mvw_base
GROUP BY category;

-- Required for REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX IF NOT EXISTS idx_lock_test_mvw_category
    ON lock_test_mvw(category);



-- ---------------------------------------------------------------------------
-- 6. Workflow jobs table
--    Used by: application workflow blockage (17)
--    Models a SysCloud job queue where workers lock rows with FOR UPDATE.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lock_test_workflow_jobs (
    id         serial       PRIMARY KEY,
    job_key    text         UNIQUE NOT NULL,
    status     text         NOT NULL DEFAULT 'PENDING',
    payload    jsonb,
    updated_at timestamptz  NOT NULL DEFAULT now()
);

TRUNCATE lock_test_workflow_jobs;

INSERT INTO lock_test_workflow_jobs (job_key, status, payload)
VALUES
    ('backup-user-1001', 'RUNNING',  '{"user_id": 1001}'),
    ('backup-user-1002', 'PENDING',  '{"user_id": 1002}'),
    ('restore-user-2001','PENDING',  '{"user_id": 2001}'),
    ('export-user-3001', 'RUNNING',  '{"user_id": 3001}'),
    ('export-user-3002', 'PENDING',  '{"user_id": 3002}');



-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

SELECT table_name,
       pg_size_pretty(pg_total_relation_size(quote_ident(table_name))) AS size
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name LIKE 'lock_test%'
  AND  table_type = 'BASE TABLE'
ORDER  BY table_name;
