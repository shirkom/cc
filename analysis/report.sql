-- Agent workload report, "seen from the PostgreSQL side".
-- Run after analysis/load_logs.sql (and optionally after loading results/runs.csv):
--   psql -d shop -f analysis/report.sql
\pset footer off
\pset null '-'

\echo
\echo '=== 1. Workload overview per role ==='
SELECT user_name                                    AS role,
       count(*)                                     AS statements,
       count(DISTINCT session_id)                   AS sessions,
       count(DISTINCT run_id)                       AS runs,
       round(count(*)::numeric / nullif(count(DISTINCT run_id), 0), 1) AS stmts_per_run
FROM lab.statements
WHERE user_name LIKE 'agent_%'
GROUP BY 1 ORDER BY 2 DESC;

\echo
\echo '=== 2. Statement mix (%) per role: how much is exploration vs. real work ==='
SELECT user_name AS role,
       round(100.0 * count(*) FILTER (WHERE sql_class = 'metadata')    / count(*), 1) AS metadata,
       round(100.0 * count(*) FILTER (WHERE sql_class = 'read')        / count(*), 1) AS read,
       round(100.0 * count(*) FILTER (WHERE sql_class = 'dml')         / count(*), 1) AS dml,
       round(100.0 * count(*) FILTER (WHERE sql_class = 'ddl')         / count(*), 1) AS ddl,
       round(100.0 * count(*) FILTER (WHERE sql_class = 'transaction') / count(*), 1) AS txn,
       round(100.0 * count(*) FILTER (WHERE sql_class IN ('session','other')) / count(*), 1) AS other
FROM lab.statements
WHERE user_name LIKE 'agent_%'
GROUP BY 1 ORDER BY 1;

\echo
\echo '=== 3. Per-run trajectory: exploration length, retries, redundancy ==='
WITH s AS (
    SELECT *, row_number() OVER (PARTITION BY run_id ORDER BY log_time, session_line_num) AS n
    FROM lab.statements WHERE run_id IS NOT NULL
)
SELECT s.run_id,
       max(r.scenario_id)                                   AS scenario,
       max(s.user_name)                                     AS role,
       count(*)                                             AS stmts,
       coalesce(min(n) FILTER (WHERE sql_class IN ('read','dml')), 0) - 1 AS stmts_before_first_data_query,
       count(*) - count(DISTINCT sql_fingerprint)           AS repeated_stmts,
       (SELECT count(*) FROM lab.errors e WHERE e.run_id = s.run_id) AS errors,
       round(extract(epoch FROM max(s.log_time) - min(s.log_time))::numeric, 2) AS db_span_s,
       max(r.tool_calls)                                    AS tool_calls
FROM s LEFT JOIN lab.runs r USING (run_id)
GROUP BY s.run_id ORDER BY min(s.log_time);

\echo
\echo '=== 4. Errors by SQLSTATE: what the agents get wrong ==='
SELECT sql_state_code AS sqlstate,
       CASE sql_state_code
           WHEN '42501' THEN 'insufficient privilege (hit a permission boundary)'
           WHEN '42P01' THEN 'undefined table (guessed a table name)'
           WHEN '42703' THEN 'undefined column (guessed a column name)'
           WHEN '42601' THEN 'syntax error'
           WHEN '42883' THEN 'undefined function / wrong types'
           WHEN '25006' THEN 'write in read-only transaction'
           WHEN '57014' THEN 'cancelled (statement_timeout)'
           WHEN '55P03' THEN 'lock not available (lock_timeout)'
           WHEN '40P01' THEN 'deadlock'
           WHEN '40001' THEN 'serialization failure'
           WHEN '23505' THEN 'unique violation'
           WHEN '23503' THEN 'foreign key violation'
           WHEN '23514' THEN 'check violation'
           ELSE ''
       END AS meaning,
       user_name AS role,
       count(*) AS n
FROM lab.errors
WHERE user_name LIKE 'agent_%'
GROUP BY 1, 2, 3 ORDER BY n DESC;

\echo
\echo '=== 5. What agents do right after "permission denied" (probing / workarounds) ==='
WITH denied AS (
    SELECT run_id, session_id, log_time, sql FROM lab.errors
    WHERE sql_state_code IN ('42501', '25006') AND run_id IS NOT NULL
)
SELECT d.run_id,
       left(lab.strip_comments(d.sql), 70) AS denied_statement,
       nxt.k                               AS next_n,
       left(lab.strip_comments(nxt.sql), 90) AS next_statement
FROM denied d
CROSS JOIN LATERAL (
    SELECT sql, row_number() OVER (ORDER BY log_time, session_line_num) AS k
    FROM lab.statements s
    WHERE s.run_id = d.run_id AND s.log_time > d.log_time
    ORDER BY log_time, session_line_num LIMIT 3
) nxt
ORDER BY d.log_time, nxt.k;

\echo
\echo '=== 6. Access to sensitive objects (PII, salaries, tokens, RLS setting) ==='
SELECT user_name AS role, run_id, succeeded, left(lab.strip_comments(sql), 100) AS statement
FROM lab.sensitive_access
WHERE user_name LIKE 'agent_%'
ORDER BY log_time;

\echo
\echo '=== 7. Risky query shapes ==='
SELECT user_name AS role,
       count(*) FILTER (WHERE lab.strip_comments(sql) ~* '^select\s+\*')                                AS select_star,
       count(*) FILTER (WHERE sql_class = 'read' AND lab.strip_comments(sql) !~* '\mlimit\M'
                                              AND lab.strip_comments(sql) !~* '\m(count|sum|avg|min|max)\s*\(') AS unbounded_reads,
       count(*) FILTER (WHERE lab.strip_comments(sql) ~* '^(update|delete)\M' AND lab.strip_comments(sql) !~* '\mwhere\M') AS dml_without_where,
       count(*) FILTER (WHERE lab.strip_comments(sql) ~ ';\s*\S')                                       AS multi_statement
FROM lab.statements
WHERE user_name LIKE 'agent_%' AND sql_class <> 'metadata'
GROUP BY 1 ORDER BY 1;

\echo
\echo '=== 8. Redundancy: the same statement issued again and again (cache/plan reuse opportunity) ==='
SELECT count(*) AS times, count(DISTINCT run_id) AS in_runs, max(sql_class) AS class,
       left(min(lab.strip_comments(sql)), 100) AS statement
FROM lab.statements
WHERE user_name LIKE 'agent_%'
GROUP BY sql_fingerprint
HAVING count(*) > 1
ORDER BY times DESC LIMIT 15;

\echo
\echo '=== 9. Connections: how the agent platform uses sessions ==='
SELECT user_name AS role,
       count(*) FILTER (WHERE message LIKE 'connection authorized%') AS connections,
       round(avg(extract(epoch FROM substring(message FROM 'session time: ([0-9:.]+)')::interval))
             FILTER (WHERE message LIKE 'disconnection%')::numeric, 2) AS avg_session_s
FROM lab.pg_log
WHERE user_name LIKE 'agent_%'
GROUP BY 1 ORDER BY 1;

\echo
\echo '=== 10. Most expensive agent statements (pg_stat_statements) ==='
SELECT r.rolname AS role, s.calls,
       round(s.total_exec_time::numeric, 1) AS total_ms,
       round(s.mean_exec_time::numeric, 2)  AS mean_ms,
       s.rows, s.shared_blks_read AS blks_read, s.temp_blks_written AS temp_written,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 80) AS query
FROM pg_stat_statements s JOIN pg_roles r ON r.oid = s.userid
WHERE r.rolname LIKE 'agent_%'
ORDER BY s.total_exec_time DESC LIMIT 15;
