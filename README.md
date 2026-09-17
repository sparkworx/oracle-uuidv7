# oracle-uuidv7

RFC 9562 **version 7 UUIDs as `RAW(16)`** for Oracle Database 19c, in pure PL/SQL,
built to stand in for `some_sequence.NEXTVAL` on insert-heavy tables.

```sql
INSERT INTO orders (id, customer_id) VALUES (uuid_v7.generate, :cust);

SELECT uuid_v7.to_string(id), uuid_v7.timestamp_of(id) FROM orders;
-- 0199583c-6a1f-7e0b-8a53-0c1d6b0f2e91   2026-09-17 16:41:07.103 +00:00
```

## Install

```
-- once, as a DBA:
GRANT EXECUTE ON SYS.DBMS_CRYPTO TO app_schema;

$ sqlplus app_schema/...@db @install.sql
$ sqlplus app_schema/...@db @test/test_uuid_v7.sql     # optional, ~1 min
$ sqlplus app_schema/...@db @bench/bench.sql           # optional
```

If the `DBMS_CRYPTO` grant is not obtainable, `@install.sql no_crypto` compiles a
variant that draws its random bits from `DBMS_RANDOM` instead (not a CSPRNG; fine
for uniqueness, not for unguessability).

The install compiles the package natively at `PLSQL_OPTIMIZE_LEVEL = 3`. To let other
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

The per-call work is: `SYSTIMESTAMP`, two timestamp comparisons, one
`EXTRACT(SECOND ...)`, a handful of integer operations and four `UTL_RAW` calls.

* Epoch conversion (timestamp → interval → day/hour/minute arithmetic) is done
  **once per wall-clock minute** and cached; within the minute only the seconds
  field is read.
* Random bytes are pulled from `DBMS_CRYPTO.RANDOMBYTES` **2000 at a time** (250
  UUIDs), and the variant bits are stamped onto the whole buffer with two
  `UTL_RAW` bit operations at refill time, so each UUID just slices 8 bytes.
* No SQL is executed inside the package, so there are no recursive calls or
  context switches — unlike `seq.NEXTVAL` in a PL/SQL expression, which runs a
  `SELECT ... FROM dual` under the covers.

### Why not Java

An OJVM stored procedure pays a SQL/PLSQL→Java call boundary on every invocation
and a JVM initialisation in every new session, needs the JAVAVM component installed
and patched, and still could not be used in a column `DEFAULT`. There is nothing in
this algorithm that Java does faster than the few built-ins used here, so PL/SQL
wins on both speed and operational simplicity.

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
