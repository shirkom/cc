-- Load results/runs.csv (written by scripts/run_scenarios.py) into lab.runs.
-- Client-side \copy, so run it from the repository root:
--   psql -h localhost -U lab_admin -d shop -f analysis/load_runs.sql
CREATE TEMP TABLE runs_in (LIKE lab.runs);
\copy runs_in FROM 'results/runs.csv' WITH (FORMAT csv, HEADER true)
INSERT INTO lab.runs SELECT * FROM runs_in ON CONFLICT (run_id) DO NOTHING;
SELECT count(*) AS runs_loaded FROM lab.runs;
