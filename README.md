# oracle-uuidv7

RFC 9562 **version 7 UUIDs as `RAW(16)`** for Oracle Database 19c, in pure PL/SQL,
built to stand in for `some_sequence.NEXTVAL` on insert-heavy tables.

```sql
INSERT INTO orders (id, customer_id) VALUES (uuid_v7.generate, :cust);

SELECT uuid_v7.to_string(id), uuid_v7.timestamp_of(id) FROM orders;
-- 01a0b0f8-bbc9-73b2-a37b-eae4a6ce258e   2026-09-17 20:04:46.153 +00:00
```

## Install

```
-- once, as a DBA:
GRANT EXECUTE ON SYS.DBMS_CRYPTO TO app_schema;

$ sqlplus app_schema/...@db @install.sql
$ sqlplus app_schema/...@db @test/test_uuid_v7.sql     # optional, ~1 min
$ sqlplus app_schema/...@db @bench/bench.sql           # optional
```

Install options, in any order: `@install.sql [no_crypto] [coarse_clock]`

* `no_crypto` — draw random bits from `DBMS_RANDOM` instead, for schemas that cannot
  get the `DBMS_CRYPTO` grant (not a CSPRNG; fine for uniqueness, not for
  unguessability).
* `coarse_clock` — ~40% less CPU per UUID in exchange for embedded timestamps that
  may lag by up to 10 ms; see *Why it is fast*. Recommended for bulk-insert keys.

The install compiles the package natively at `PLSQL_OPTIMIZE_LEVEL = 3`. Where
native compilation is unavailable the install falls back to interpreted code by
itself: Linux ARM ports (`PLS-00924` warning) and hosts whose `/dev/shm` is mounted
`noexec`, e.g. Docker defaults (`ORA-00600 [pesldl03_MMap]`). To let other
schemas use it: `GRANT EXECUTE ON uuid_v7 TO ...` plus a synonym.

## API

| Function | Returns | |
|---|---|---|
| `uuid_v7.generate` | `RAW(16)` | next UUIDv7 |
| `uuid_v7.to_string(raw)` | `VARCHAR2(36)` | canonical lower-case `8-4-4-4-12` text |
| `uuid_v7.from_string(text)` | `RAW(16)` | hyphens optional, any case |
| `uuid_v7.timestamp_of(raw)` | `TIMESTAMP WITH TIME ZONE` | embedded creation time (ms, UTC) |

## Design

| bits | content |
|---|---|
| 48 | Unix epoch milliseconds, big-endian |
| 4 | version `0111` |
| 12 | sub-millisecond clock fraction (1/4096 ms) |
| 2 | variant `10` |
| 62 | random, fresh for every UUID |

* **Ordering.** The 12 `rand_a` bits hold extra clock precision (RFC 9562 §6.2
  method 3, the same layout PostgreSQL 18 uses). Inside a session the 60-bit
  timestamp is forced to be *strictly increasing*: if the clock has not advanced, or
  has stepped backwards, the generator counts up from the last value instead. One
  session therefore always produces keys in ascending order, exactly like a sequence.
  Between sessions (and RAC instances) ordering follows the wall clock.
* **Uniqueness** across sessions rests on 62 random bits per UUID on top of a
  ~244 ns timestamp; no coordination, no shared state, no latch.
* **`RAW` compares bytewise**, so `ORDER BY id` and the primary key index are
  chronological. Like a sequence-fed key it is a right-growing index: 90/10 leaf
  splits and a compact index, but also the same hot right-hand leaf block under many
  concurrent inserters.

### Why it is fast

Everything below was chosen by measurement (see *Benchmarks*), not by guesswork:

* **No SQL inside the package** — no recursive calls or context switches. Compare
  `seq.NEXTVAL` in a PL/SQL expression, which runs a `SELECT ... FROM dual` under
  the covers and is ~2x slower than `uuid_v7.generate` there.
* **Hex-string assembly, one `HEXTORAW`.** `UTL_RAW.*` calls cost 0.3–0.5 µs each,
  native `HEXTORAW`/`SUBSTRB`/`||` a few hundredths. The
  first version of this package built the value with four `UTL_RAW` calls and took
  4.1 µs; the string version takes 2.6 µs.
* **`SUBSTRB`, never `SUBSTR`,** on the lookup strings: in an AL32UTF8 database
  `SUBSTR` scans from the start of the string to find a character offset (this was a
  10x slowdown in one prototype).
* **Epoch conversion once per minute.** Timestamp → interval → day/hour/minute
  arithmetic is cached; within the minute only `EXTRACT(SECOND ...)` is needed.
* **Hex of the 48-bit millisecond field is cached** until the millisecond changes;
  the 12 fraction bits come from a 256-entry lookup string.
* **Random bits in bulk:** `DBMS_CRYPTO.RANDOMBYTES` is called once per 250 UUIDs
  and the variant bits are stamped onto the whole pool with two bit operations.
* Things that were measured and *rejected*: `PRAGMA UDF` wrappers (no real gain),
  integer-only arithmetic (no gain over `NUMBER`), a 4096-entry fraction table
  (0.1 µs faster, but ~2 ms of session start-up).

What is left is dominated by `SYSTIMESTAMP` itself (~0.9 µs of the 2.6 µs). The
**`coarse_clock`** install option removes most of that: the clock is read only when
the centisecond tick counter (`DBMS_UTILITY.GET_TIME`, 0.15 µs) has moved, and values
count up from the last one in between. Ordering and uniqueness guarantees are
identical; the only difference is that the embedded timestamp can lag the wall clock
by up to 10 ms. **For a pure surrogate key fed by bulk inserts, install with
`coarse_clock`.** Keep the default if you rely on `timestamp_of` being exact to the
millisecond.

First call in a session (package instantiation + first random pool) costs ~0.5 ms.

## Benchmarks

`bench/bench.sql`, single session, table with a primary key, Oracle 23.26 Free in
Docker on an Apple-silicon laptop (PL/SQL *interpreted* — that port has no native
compilation; expect the PL/SQL share to shrink on x86-64 19c where `install.sql`
compiles natively). Absolute numbers will differ on your hardware; run it there.

| µs per row | `seq.NEXTVAL` | `SYS_GUID()` | `uuid_v7` | `uuid_v7` `coarse_clock` |
|---|---|---|---|---|
| key generation only, PL/SQL loop | 5.6 | 0.4 | 2.6 | 1.5 |
| row-by-row `INSERT ... VALUES`, PL/SQL loop | 13.6 | 12.1 | 19–20 | 15.6–17.6 |
| `FORALL` insert, keys generated in PL/SQL | 6.6 | – | 3.5 | 2.4 |
| `INSERT ... SELECT` | 1.4 | 0.9 | 5.1 | 3.6 |

Reading the table:

* The insert itself costs the same for v7 keys as for `SYS_GUID()` keys (11.2–11.7
  µs/row with pre-generated keys) — index maintenance is identical, as expected for
  ascending keys.
* `FORALL` with keys generated in PL/SQL is the fastest path and **beats the
  sequence** by almost 2x.
* Inside a SQL statement a sequence is a kernel operation and cannot be matched by
  any PL/SQL (or Java) function: budget ~2–4 µs per row extra for
  `INSERT ... SELECT`, and ~2–6 µs per row for row-by-row inserts.

Also verified: 8 concurrent sessions × 100,000 inserts into one primary-keyed table —
800,000 distinct keys, no `ORA-00001`, every session's keys in generation order.

## Behaviour under high concurrency

`generate` touches **no shared structure** per call: no SQL, no sequence, no latch,
no enqueue, no row cache. All state (last timestamp, random pool, ~8 KB) lives in the
session's own memory. The default and `coarse_clock` builds are identical in this
respect — the clock choice is a pure CPU trade-off (~1 µs per UUID) and cannot create
or remove contention.

Library cache behaviour, measured via `v$librarycache` pin deltas:

| calling pattern | package pins |
|---|---|
| 100,000 `generate` calls in one PL/SQL block | 0 |
| one `INSERT ... SELECT` of 100,000 rows | ~0 (noise) |
| 100,000 `INSERT ... VALUES (uuid_v7.generate, ...)` inside one PL/SQL call | ~0; the only per-execution pin is on the cursor, same as `SYS_GUID()` |
| INSERTs issued one by one from a client | ~5 shared-mode pins per top-level call (spec, body, dependencies) |

So the package is pinned (shared) once per *top-level call*, never per UUID. Shared
pins do not block each other; each is a sub-microsecond mutex operation. That only
becomes visible (`library cache: mutex X`) at tens of thousands of top-level calls
per second against one object on a large SMP box — if you ever get there,
`DBMS_SHARED_POOL.MARKHOT` on the package spreads it — and long before that the usual
suspects dominate: the INSERT cursor's own mutex (`cursor: pin S`), redo, and above
all the **right-hand index leaf block** (`buffer busy waits`, `enq: TX - index
contention`, `gc buffer busy` on RAC), which any ascending key shares with
sequences. A global hash-partitioned primary key index is the standard remedy.
Relative to a sequence, this generator *removes* contention points: no `seq$`
updates, `row cache lock` or `enq: SQ/SV` waits, and nothing to coordinate in RAC.

The one real library cache hazard is **DDL against the package while it is busy**.
`CREATE OR REPLACE`/`ALTER ... COMPILE` needs an exclusive pin: it waits for every
in-flight top-level call using the package (`library cache pin`), new callers queue
behind it, and afterwards every session holding package state takes one `ORA-04068`.
Deploy in a quiet window (or via edition-based redefinition) and never recompile it
casually under load.

Host-level: `SYSTIMESTAMP` is a `clock_gettime` vDSO call — lock-free with
`clocksource=tsc`/`kvm-clock`. On a VM stuck with `hpet`/`acpi_pm` clock reads are
slow and serialised system-wide; Oracle's own wait-event timing suffers from that
long before this package does, but it is the one scenario where `coarse_clock` also
helps concurrency.

## What about 23ai / 26ai?

Newer releases have a native `UUID()` SQL function (plus `RAW_TO_UUID` /
`UUID_TO_RAW`), but as of 23.26.3 it only produces **version 4**: `UUID(7)` raises
`ORA-62433`. Random v4 keys scatter inserts across the whole primary key index, so
this package remains the better key source there too.

Tested on 19c EE 19.26 (x86-64) and 23.26 Free (ARM); same source, all tests pass.

## Why not Java

Not benchmarked, deliberately. An OJVM stored procedure adds a call boundary on
every invocation and JVM initialisation in every new session, needs the JAVAVM
component installed and patched, and still could not be used in a column `DEFAULT`.
The remaining cost here is `SYSTIMESTAMP` plus a few C built-ins; there is no
computation left for a JIT to speed up, so Java adds overhead and operational
burden without a way to win.

## Usage notes

* **No column `DEFAULT`.** 19c only allows sequences and built-ins in `DEFAULT`
  expressions, not PL/SQL functions. Put `uuid_v7.generate` in the `INSERT`
  statement (fastest), or assign it in a `BEFORE INSERT` row trigger
  (`:new.id := uuid_v7.generate;`) if the application cannot be changed.
* **Bulk loads from PL/SQL:** generate the keys into a collection and `FORALL`
  insert — generation then runs with no SQL↔PL/SQL switching at all.
* **Do not wrap the call in a scalar subquery** (`(SELECT uuid_v7.generate FROM
  dual)`): scalar subquery caching would hand the same value to every row.
* The package keeps session state (last timestamp, random pool). Recompiling it
  under live sessions gives them one `ORA-04068`, as with any stateful package.
* `generate` is `PARALLEL_ENABLE`d; PX servers are separate sessions, so parallel
  DML yields unique keys that are ordered per PX server.
* If the OS clock is stepped backwards, a running session keeps issuing ascending
  keys from its last timestamp until the clock catches up.
