-- Save the current pg_stat_statements counters for the agent roles.
--   psql -d shop -v label=after_run1 -f analysis/snapshot.sql
INSERT INTO lab.stmt_snapshots (label, rolname, queryid, query, calls, total_exec_time,
                                rows, shared_blks_hit, shared_blks_read, temp_blks_written)
SELECT :'label', r.rolname, s.queryid, s.query, s.calls, s.total_exec_time,
       s.rows, s.shared_blks_hit, s.shared_blks_read, s.temp_blks_written
FROM pg_stat_statements s
JOIN pg_roles r ON r.oid = s.userid
WHERE r.rolname LIKE 'agent_%';
