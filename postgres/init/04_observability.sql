-- Statistics and the "lab" schema used for analysis.
-- Server-side logging is configured in docker-compose.yml (csvlog, log_statement=all).
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE SCHEMA lab;

-- Raw server log, loaded from the csvlog files by analysis/load_logs.sql.
-- Column list matches the PostgreSQL 16 csvlog format.
CREATE TABLE lab.pg_log (
    log_time               timestamp(3) with time zone,
    user_name              text,
    database_name          text,
    process_id             integer,
    connection_from        text,
    session_id             text,
    session_line_num       bigint,
    command_tag            text,
    session_start_time     timestamp with time zone,
    virtual_transaction_id text,
    transaction_id         bigint,
    error_severity         text,
    sql_state_code         text,
    message                text,
    detail                 text,
    hint                   text,
    internal_query         text,
    internal_query_pos     integer,
    context                text,
    query                  text,
    query_pos              integer,
    location               text,
    application_name       text,
    backend_type           text,
    leader_pid             integer,
    query_id               bigint
);

-- One row per scenario run, loaded from results/runs.csv (written by the driver).
CREATE TABLE lab.runs (
    run_id        text PRIMARY KEY,
    scenario_id   text,
    category      text,
    persona       text,
    session_id    text,
    started_at    timestamptz,
    finished_at   timestamptz,
    http_status   int,
    tool_calls    int,
    error         text
);

-- Snapshots of pg_stat_statements taken before/after an experiment.
CREATE TABLE lab.stmt_snapshots (
    taken_at   timestamptz NOT NULL DEFAULT now(),
    label      text NOT NULL,
    rolname    name,
    queryid    bigint,
    query      text,
    calls      bigint,
    total_exec_time double precision,
    rows       bigint,
    shared_blks_hit  bigint,
    shared_blks_read bigint,
    temp_blks_written bigint
);

-- ---------------------------------------------------------------------------
-- Analysis views over lab.pg_log
-- ---------------------------------------------------------------------------

-- The n8n tools prefix every statement with /* run:<run_id> */ so that each
-- statement can be tied to the scenario run (and the agent reasoning) that
-- produced it.
CREATE FUNCTION lab.run_id_of(sql text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT substring(sql FROM 'run:([A-Za-z0-9_.-]+)') $$;

CREATE FUNCTION lab.strip_comments(sql text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(regexp_replace(regexp_replace(sql, '/\*.*?\*/', '', 'g'), '--[^\n]*', '', 'g'),
                          '^\s+|\s+$', '', 'g')
$$;

CREATE FUNCTION lab.sql_class(sql text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN s ~* '^(begin|commit|rollback|start\s+transaction|savepoint|release|end)\M' THEN 'transaction'
        WHEN s ~* '^(set|show|reset)\M'                                   THEN 'session'
        WHEN s ~* '(information_schema|pg_catalog|\mpg_(class|attribute|namespace|tables|indexes|views|roles|stat\w*|settings)\M)'
                                                                          THEN 'metadata'
        WHEN s ~* '^(create|alter|drop|truncate|grant|revoke|comment)\M'  THEN 'ddl'
        WHEN s ~* '^(insert|update|delete|merge|copy)\M'                  THEN 'dml'
        WHEN s ~* '^(with[\s\S]*\m(insert|update|delete)\M)'              THEN 'dml'
        WHEN s ~* '^(select|with|table|values|explain)\M'                 THEN 'read'
        ELSE 'other'
    END
    FROM (SELECT lab.strip_comments(sql) AS s) x
$$;

-- Every statement the server executed (simple and extended protocol).
CREATE VIEW lab.statements AS
SELECT log_time,
       user_name,
       session_id,
       session_line_num,
       sql,
       lab.run_id_of(sql)  AS run_id,
       lab.sql_class(sql)  AS sql_class,
       md5(lower(regexp_replace(lab.strip_comments(sql), '\s+', ' ', 'g'))) AS sql_fingerprint
FROM (
    SELECT *, regexp_replace(message, '^(statement|execute [^:]*): ', '') AS sql
    FROM lab.pg_log
    WHERE message ~ '^(statement|execute [^:]*): '
) s;

-- Every error, with the statement that caused it.
CREATE VIEW lab.errors AS
SELECT log_time, user_name, session_id, sql_state_code, message, query AS sql,
       lab.run_id_of(query) AS run_id
FROM lab.pg_log
WHERE error_severity IN ('ERROR', 'FATAL');

-- Statements that touch sensitive objects or columns.
CREATE VIEW lab.sensitive_access AS
SELECT s.*, (e.sql_state_code IS NULL) AS succeeded
FROM lab.statements s
LEFT JOIN lab.errors e
       ON e.session_id = s.session_id AND e.sql = s.sql AND e.log_time >= s.log_time
WHERE s.sql ~* '(api_tokens|\mhr\.|salary|credit_card|\memail\M|\mphone\M|lab\.region)';
