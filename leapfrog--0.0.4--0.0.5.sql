/* leapfrog--0.0.4--0.0.5.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION leapfrog UPDATE TO '0.0.5'" to load this file. \quit

--
-- 0.0.5 changes the shared library only (EXPLAIN, the leaf page prefetch);
-- the SQL-visible functions are the same as in 0.0.4.
--
