-- =============================================================================
-- 05_throttle_and_drain.sql
-- Connection Exhaustion - Throttling & Emergency Drain Templates
-- SysCloud DAL Team
--
-- These are templated actions, not a single pipeline — run the relevant
-- block manually based on RCA findings. Replace <PLACEHOLDER> values before
-- running.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A. Throttle a high-load role (persistent, survives reconnects)
--    Use when one role (e.g. a worker pool) is starving other workloads.
-- -----------------------------------------------------------------------------
ALTER ROLE <ROLE_NAME> CONNECTION LIMIT <N>;

-- Revert / remove the limit:
-- ALTER ROLE <ROLE_NAME> CONNECTION LIMIT -1;

-- -----------------------------------------------------------------------------
-- B. Throttle at the database level
-- -----------------------------------------------------------------------------
ALTER DATABASE <DB_NAME> CONNECTION LIMIT <N>;

-- Revert:
-- ALTER DATABASE <DB_NAME> CONNECTION LIMIT -1;

-- -----------------------------------------------------------------------------
-- C. Session-scoped safe dynamic mitigations (no restart required)
--    Useful when a leak/storm is caused by one role holding transactions
--    or queries open too long.
-- -----------------------------------------------------------------------------
-- ALTER ROLE <ROLE_NAME> SET idle_in_transaction_session_timeout = '60s';
-- ALTER ROLE <ROLE_NAME> SET statement_timeout = '120s';
-- ALTER ROLE <ROLE_NAME> SET lock_timeout = '5s';

-- -----------------------------------------------------------------------------
-- D. PgBouncer emergency commands
--    Run these against the PgBouncer admin console, NOT the RDS endpoint:
--      psql -h <pgbouncer-host> -p <port> -U postgres pgbouncer
-- -----------------------------------------------------------------------------

-- Emergency widen of max_client_conn (non-persistent until config file updated)
-- SET max_client_conn = 150000;
-- RELOAD;

-- Pause a database before planned RDS maintenance (waits for in-flight txns)
-- PAUSE <DB_NAME>;

-- Forcibly drop all connections to a database (last resort)
-- KILL <DB_NAME>;

-- Bring a paused/killed database back online
-- RESUME <DB_NAME>;

-- Confirm a config change actually applied
-- SHOW CONFIG;

-- -----------------------------------------------------------------------------
-- E. Verify after any throttle change
-- -----------------------------------------------------------------------------
SELECT rolname, rolconnlimit FROM pg_roles WHERE rolconnlimit <> -1;
SELECT datname, datconnlimit FROM pg_database WHERE datconnlimit <> -1;
