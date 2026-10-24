/* leapfrog--0.0.2.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION leapfrog" to load this file. \quit

--
-- The extension works through a planner hook that is installed when the
-- shared library is loaded (shared_preload_libraries, session_preload_libraries
-- or LOAD).  CREATE EXTENSION registers the SQL-visible helpers below; creating
-- a C function also loads the library into the current session.
--

CREATE FUNCTION leapfrog_version()
RETURNS text
AS 'MODULE_PATHNAME', 'leapfrog_version'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

COMMENT ON FUNCTION leapfrog_version() IS
'Version of the leapfrog shared library loaded into this session';

CREATE FUNCTION leapfrog_is_loaded()
RETURNS boolean
AS 'MODULE_PATHNAME', 'leapfrog_is_loaded'
LANGUAGE C STABLE PARALLEL SAFE;

COMMENT ON FUNCTION leapfrog_is_loaded() IS
'True when the planner hook of leapfrog is active in this session';
