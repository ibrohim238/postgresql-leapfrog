/* leapfrog--0.0.2--0.0.3.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION leapfrog UPDATE TO '0.0.3'" to load this file. \quit

--
-- 0.0.3 changes the shared library only (planner, cost model, executor);
-- the SQL-visible functions are the same as in 0.0.2.
--
