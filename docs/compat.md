# PostgreSQL version shims

Every difference between the PostgreSQL major versions the extension builds
against is in `src/compat.h`; the `.c` files test no `PG_VERSION_NUM`
themselves. `PG_VERSION_18` and `PG_VERSION_19` name the version numbers; an
older server stops the build with `#error`.

| Shim | Release | Commit | What changed in core |
|---|---|---|---|
| `lf_index_beginscan(heap, index, snapshot, nkeys)` | PostgreSQL 19 | `dcd8cc1c852c` "Thread flags through begin-scan APIs" | `index_beginscan` takes a table AM flags argument; the shim passes `SO_NONE`, no instrumentation and no ORDER BY keys |
| `lf_node_need_timer`, `lf_node_need_bufusage`, `lf_node_nloops` | PostgreSQL 19 | `5a79e78501f4` "instrumentation: Separate per-node logic from other uses" | `PlanState.instrument` is a `NodeInstrumentation`: it keeps the loop count and wraps the timer and buffer usage flags in an `Instrumentation` of its own (field `instr`); `nloops` stays where it was |
| `LF_DATUM_IS_64BIT` | PostgreSQL 19 | `2a600a93c7be` "Make type Datum be 8 bytes wide everywhere" | `Datum` holds an `int64` by value on every platform, before only where `SIZEOF_DATUM` is 8; sort support may pick `ssup_datum_signed_cmp`, which `sortsupport.h` declares only then |
| `LF_PLANNER_ARGS`, `LF_PLANNER_CALL(fn)` | PostgreSQL 19 | `c83ac02ec730` "Add ExplainState argument to pg_plan_query() and planner()" | `planner_hook` and `standard_planner` take the `ExplainState` of an EXPLAIN, NULL otherwise |

A new shim goes into `src/compat.h` with one line naming the release, the
commit and the change, and a row here.
