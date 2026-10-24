-- Runs once when the data directory is initialised: install the extension
-- into the default database and create a database for the regression tests.
CREATE EXTENSION IF NOT EXISTS leapfrog;
SELECT leapfrog_version();
