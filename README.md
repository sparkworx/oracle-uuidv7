# oracle-uuidv7

RFC 9562 **version 7 UUIDs as `RAW(16)`** for Oracle Database 19c, in pure PL/SQL,
built to stand in for `some_sequence.NEXTVAL` on insert-heavy tables.

```sql
INSERT INTO orders (id, customer_id) VALUES (uuid_v7.generate, :cust);

SELECT uuid_v7.to_string(id), uuid_v7.timestamp_of(id) FROM orders;
-- 01a0b0f8-bbc9-73b2-a37b-eae4a6ce258e   2026-09-17 20:04:46.153 +00:00
```

## Why UUIDv7 instead of a sequence

The short version: an Oracle sequence promises *unique numbers*, and nothing else.
Everything people assume on top of that — ordered, gapless, never reissued,
meaningful across systems — is an assumption the database does not back, and on RAC
it stops being even approximately true. UUIDv7 gives you an identifier that is unique
everywhere, sorts by time, tells you when it was minted, and needs no coordination
at all.

### The case that prompted this: HL7 `MSH-10` Message Control ID

HL7 v2 asks exactly one thing of `MSH-10`: that it **uniquely identifies the
message**, so the receiver can echo it in `MSA-2` and the sender can match the ACK.
It is a string (`ST`), not a number, and the standard says nothing about ordering —
ordered delivery is what `MSH-13` *Sequence Number* and the sequence number protocol
exist for. A receiver that enforces "monotonically increasing integer" on `MSH-10`
is enforcing something that neither HL7 nor Oracle guarantees:

| What the integer-sequence assumption needs | What an Oracle sequence actually does |
|---|---|
| Values arrive in increasing order | `NEXTVAL` order is not send order. Two sessions draw 1041 and 1042; 1042 finishes building its message first. Any sender with more than one session violates this, on any database. |
| Increasing across the cluster | On RAC each instance caches its own range (`NOORDER`, the default): node 1 hands out 1–20 while node 2 hands out 21–40, interleaved in time. |
| ...so use `ORDER`? | `ORDER` makes every `NEXTVAL` a cluster-wide synchronization (`enq: SV`, `row cache lock`, `seq$` block pings). You pay global serialization on every message to prop up a guarantee the first row already lost. |
| No gaps | Rollbacks, instance crashes, shared pool aging and cache flushes all burn values. Gapless sequences do not exist. |
| Never reissued | A point-in-time restore, a flashback, a refreshed clone or a recreated sequence hands out numbers the partner has already seen — silently. |
| Unique per sender | `48213` from PROD, from TEST, from the DR site and from the facility you merge with next year are the same control ID. |

UUIDv7 replaces those assumptions with properties that actually hold:

* **Globally unique with zero coordination.** No registry, no per-instance ranges,
  no cluster traffic. RAC node, DR site, test clone, acquired hospital: no
  collisions, nothing to configure.
* **Cannot be reissued.** The leading 48 bits are the wall clock. A restored or
  cloned database keeps minting *new* identifiers, because time has moved on.
* **Time-ordered where that is physically meaningful.** Strictly increasing within a
  session; across sessions and RAC instances ordered by clock, to the precision of
  the cluster's time sync (which Grid Infrastructure already enforces). That is as
  much ordering as a distributed sender can honestly offer, and it is there for
  troubleshooting and indexing, not as a wire-protocol contract.
* **Self-describing.** `uuid_v7.timestamp_of(id)` recovers when the control ID was
  minted, to the millisecond. Set against `MSH-7` and the ACK time, that is a free
  latency and forensics trail: *when was this message created, versus when it claims
  to have been sent, versus when it was acknowledged?*
* **Drop-in where UUIDs are already accepted.** Same 36-character text, same 16
  bytes as the v4 UUIDs a partner already takes; only the version digit differs.
  Hex digits and hyphens never collide with HL7 delimiters (`|^~\&`), so no escaping.
* **Better than v4 for the sender's own database.** A v4 key lands at a random spot
  in the message-log index on every insert: the whole index becomes the working set
  and leaf blocks split 50/50 forever. v7 keys append, like a sequence — compact
  index, cache-friendly, and recent messages (the ones ACK matching looks up) sit
  together in a few hot blocks.
* **Cheaper than the sequence it replaces.** No `seq$` updates, no `enq: SQ` /
  `enq: SV`, no `row cache lock`, nothing global on RAC (see *Behavior under high
  concurrency*), and 2x faster than `NEXTVAL` when called from PL/SQL.

```sql
-- building the message
l_id    := uuid_v7.generate;                 -- RAW(16): store and index this
l_msh10 := uuid_v7.to_string(l_id);          -- '01a0b0f8-bbc9-73b2-a37b-eae4a6ce258e'

-- matching the ACK
SELECT ... FROM hl7_outbound WHERE id = uuid_v7.from_string(:msa_2);
```

One thing to check with each trading partner: the length of `MSH-10`. Older versions
of the standard give it a maximum length of **20** (v2.2 attribute table: `ST`, 20,
required); current versions specify `[1..199]`, no truncation — the change came with
the min..max length notation around v2.7 (verify for the version your interface
claims). A UUID is 36 characters (32 without hyphens; 22 in Base64; 20 only in a
Base85 variant with a custom, delimiter-free alphabet). An interface that accepts
UUIDs today is already past a 20-character limit by agreement — fine, but worth
having in the interface specification rather than in folklore.

For reference, the standard's own words (current v2 text, as published by HL7 Europe). `MSH-10`: *"This field contains a number or
other identifier that uniquely identifies the message. The receiving system echoes
this ID back to the sending system in the Message acknowledgment segment (MSA)."*
`MSH-13` Sequence Number (optional, `NM`): *"A non-delete indicator value in this field
implies that the sequence number protocol is in use. This numeric field is incremented by one
for each subsequent value."* Uniqueness lives in one field, ordering in another.

What UUIDv7 deliberately does **not** claim: a global total order across sessions.
Nothing does, short of funneling every message through a single serialization
point; a sequence only appears to, until the second session or the second RAC node.
If a partner genuinely needs ordered processing, that is a transport-level concern
(one connection, `MSH-13`, or an ordered queue), not something to smuggle into an
identifier.

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

## Behavior under high concurrency

`generate` touches **no shared structure** per call: no SQL, no sequence, no latch,
no enqueue, no row cache. All state (last timestamp, random pool, ~8 KB) lives in the
session's own memory. The default and `coarse_clock` builds are identical in this
respect — the clock choice is a pure CPU trade-off (~1 µs per UUID) and cannot create
or remove contention.

Library cache behavior, measured via `v$librarycache` pin deltas:

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
behind it, and afterward every session holding package state takes one `ORA-04068`.
Deploy in a quiet window (or via edition-based redefinition) and never recompile it
casually under load.

Host-level: `SYSTIMESTAMP` is a `clock_gettime` vDSO call — lock-free with
`clocksource=tsc`/`kvm-clock`. On a VM stuck with `hpet`/`acpi_pm` clock reads are
slow and serialized system-wide; Oracle's own wait-event timing suffers from that
long before this package does, but it is the one scenario where `coarse_clock` also
helps concurrency.

## What about 23ai / 26ai?

Newer releases have a native `UUID()` SQL function (plus `RAW_TO_UUID` /
`UUID_TO_RAW`), but as of 23.26.3 it only produces **version 4**: `UUID(7)` raises
`ORA-62433`. Random v4 keys scatter inserts across the whole primary key index, so
this package remains the better key source there too.

Tested on 19c EE 19.26 (x86-64) and 23.26 Free (ARM); same source, all tests pass.
The package is pure PL/SQL and uses nothing newer than 11g: it also installs and
passes the structure, ordering and uniqueness tests on 11.2.0.2 XE (the test
script's minute-rollover step needs `DBMS_SESSION.SLEEP`, 18c+).

## Prior art

Øyvind Isene's [UUID v7 in Oracle Database](https://enesi.no/2025/12/uuid-v7-in-oracle-database/)
(December 2025) loads the npm [`uuidv7`](https://www.npmjs.com/package/uuidv7)
library into the database as an MLE JavaScript module — a few lines of glue and a
well-tested library is callable from SQL. Honorable mention: it is a neat
demonstration of what MLE is for, the post is candid about the cost, and its
benchmark is published clearly enough to reproduce, which is what made this
comparison possible. He times it against the native `UUID()` (v4) and against the
PL/SQL function `generate_uuid_v7` from Jasmin Fluri's
[How UUIDv7 makes your (database) life easier](https://medium.com/@jasminfluri/how-uuidv7-makes-your-database-life-easier-5eee3d0ff9e2).

`bench/prior_art.sql` reruns his test next to this package: both functions built
and loaded exactly as published (`uuidv7` 1.2.1, esbuild bundle, SQLcl
`mle create-module`), same statement, Oracle 23.26.3 Free in Docker on Apple
silicon. Seconds for `CREATE TABLE ... AS SELECT <generator>,
dbms_random.string('a',42) ... CONNECT BY LEVEL <= 1e6`, average of 3 runs (6 for
the first three rows — they ran alongside both builds of this package):

| one million rows, seconds | as published (enesi.no, M1 Mac mini) | reproduced here | UUID column only |
|---|---|---|---|
| native `UUID()` — v4, random | 21.5 | 19.2 | 1.0 |
| `generate_uuid_v7()` — PL/SQL, Medium article | 30.3 | 28.4 | 9.5 |
| `uuid_v7_raw()` — MLE JavaScript | 38.2 | 34.4 | 13.3 |
| **`uuid_v7.generate`** | – | **23.8** | **4.4** |
| **`uuid_v7.generate`**, `coarse_clock` | – | **20.5** | **2.8** |

His numbers reproduce to within about 10%. Some 18 of those seconds are the
`DBMS_RANDOM.STRING` filler column, identical for every row of the table, so the
last column repeats the statement without it. Per UUID, on top of the kernel's own
v4: JavaScript 12.3 µs, the PL/SQL function 8.5 µs, this package 3.4 µs — 1.8 µs
with `coarse_clock`. That is 3x faster than the MLE call and 2.2x faster than the
other PL/SQL implementation (4.8x and 3.4x with `coarse_clock`), and it closes most
of the gap to a native function that does not have to read the clock at all.

Speed aside:

* **Pure PL/SQL, back to 11g.** MLE JavaScript needs 21c or later (and, in 21c,
  was limited to `DBMS_MLE` dynamic execution; modules and call specifications
  arrived with 23ai). This package is one spec and one body with no dependencies
  beyond `DBMS_CRYPTO`, and the same source runs from 11.2 to 26ai — including the
  19c estates that will be in production for years yet.
* **`generate_uuid_v7` as published is not usable as a key.** It concatenates 4 + 2
  + 2 + 2 + 4 bytes, so it returns **14-byte** values rather than 16; it takes the
  time via `CAST(... AS DATE)`, so the "millisecond" timestamp only moves once per
  second; and with nothing but `DBMS_RANDOM` bits after it, half of all consecutive
  values sort out of order (50,116 of 100,000 in our check). It costs what it does
  because it rebuilds everything per call, through `UTL_RAW.CONCAT` and a chain of
  `TO_CHAR`/`LPAD`/`HEXTORAW` conversions — see *Why it is fast* for the alternative.
* The `uuidv7` library is correct and monotonic (42-bit counter, RFC 9562 method
  1). Inside MLE, though, its clock advanced only ~10 times per second in our run
  (13 distinct timestamps across 100,000 UUIDs generated over 1.3 s), so the
  embedded time is coarser than the format suggests.

### Generating on the client instead

Robson Kades's [`uuidv7`](https://github.com/robsonkades/uuidv7) for Java 17+ (MIT,
`io.github.robsonkades:uuidv7`) is the other interesting contrast, and in raw
generation speed it is in a different league from anything in this README. Its
published JMH figures (i7-13700K, JDK 25): **260 million UUIDs per second** on one
thread — 3.84 ns each — 118 M/s in its `SecureRandom`-per-UUID mode, over a
billion per second across 8 threads, against 74.5 M/s for the well-known
java-uuid-generator. `uuid_v7.generate` takes 2.6 µs. That is roughly 700 times
slower, and no amount of PL/SQL tuning will change the order of magnitude: a
JIT-compiled loop over thread-local state is simply a faster place to run than a
PL/SQL virtual machine.

Those numbers cannot be compared with ours, though, because none of them survive
contact with an `INSERT`. With keys already in hand, a row costs this database
about 1 µs in an array insert and 11–12 µs row by row (see *Benchmarks*), and a
client pays a network round trip on top. One session tops out around a million
rows per second in the best case — 1/250th of what the generator can supply. The
database is the bottleneck either way; past a few microseconds per key, generator
speed stops being a reason to choose anything.

So choose on architecture. Candidly:

* **If a Java application owns every insert into the table, generate on the
  client, with that library.** It is the better design, and not because of the
  260 M/s. The ID exists before the row does: no `RETURNING` clause, parent and
  child rows batched in one round trip, the same ID usable in the log line, the
  message and the other datastore. And the key costs the database nothing, which
  does matter for bulk loads — in the array-insert path our 2.6 µs of generation
  is most of the server-side cost per row. Bind it as 16 big-endian bytes into a
  `RAW(16)` column (most significant long first; never `VARCHAR2(36)`, which
  doubles the key and the index). `uuid_v7.to_string`, `from_string` and
  `timestamp_of` work on any RFC 9562 v7 value, so this package stays useful as
  the database-side decoder.
* **Know what changes.** The embedded time becomes the application hosts' clocks
  rather than the database's: many clocks instead of one, so `timestamp_of` is as
  trustworthy as your app tier's NTP. Monotonicity is per thread there as it is
  per session here; across threads and hosts both order by wall clock, to the
  millisecond.
* **Generate in the database when the database is where rows are born:** PL/SQL
  APIs and interface engines (the HL7 case above), `INSERT ... SELECT`, `MERGE`,
  ETL, triggers under applications you cannot change, or several client stacks
  of which not all have a v7 library worth trusting. One implementation, one
  clock, one guarantee, whoever the caller is — that is what this package is for.
* **Mixing is fine.** Client-generated and database-generated v7 values share a
  column happily: same layout, same index behavior, no collision risk worth
  discussing. Only the strict in-order guarantee is scoped to one generator.
* **Not on Oracle at all?** Then none of this applies. PostgreSQL 18 has a native
  `uuidv7()` and a real `uuid` type — use them. Elsewhere, use your language's v7
  library, and in Java that one is a good pick.

## Why not a Java stored procedure

Not benchmarked, deliberately — this is about Java *inside* the database; for Java
on the client see *Generating on the client instead*. An OJVM stored procedure adds
a call boundary on every invocation and JVM initialization in every new session,
needs the JAVAVM component installed and patched, and still could not be used in a
column `DEFAULT`. The remaining cost here is `SYSTIMESTAMP` plus a few C built-ins;
there is no computation left for a JIT to speed up, so Java adds overhead and
operational burden without a way to win.

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

## License

[MIT](LICENSE) © 2026 Ian Woodbury
