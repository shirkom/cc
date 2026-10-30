-- Load every csvlog file from the server log directory into lab.pg_log.
-- Run as a superuser (COPY FROM a server file):
--   psql -d shop -f analysis/load_logs.sql
TRUNCATE lab.pg_log;

DO $$
DECLARE
    dir  text := current_setting('log_directory');
    f    text;
BEGIN
    IF dir !~ '^/' THEN
        dir := current_setting('data_directory') || '/' || dir;
    END IF;
    FOR f IN SELECT name FROM pg_ls_dir(dir) AS name WHERE name LIKE '%.csv' ORDER BY name LOOP
        EXECUTE format('COPY lab.pg_log FROM %L WITH (FORMAT csv)', dir || '/' || f);
        RAISE NOTICE 'loaded %', f;
    END LOOP;
END $$;

SELECT count(*) AS log_lines,
       count(*) FILTER (WHERE user_name LIKE 'agent_%') AS agent_lines
FROM lab.pg_log;
