-- Runs once when the data directory is initialised.
CREATE EXTENSION IF NOT EXISTS leapfrog;
SELECT leapfrog_version();
