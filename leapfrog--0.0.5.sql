/* leapfrog--0.0.5.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION leapfrog" to load this file. \quit

-- The planner hook is installed when the library is loaded; creating a C function loads it.

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
