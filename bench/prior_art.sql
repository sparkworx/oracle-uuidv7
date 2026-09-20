-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Ian Woodbury
-- Benchmark against prior art, reproducing the test in
--   https://enesi.no/2025/12/uuid-v7-in-oracle-database/   (Oyvind Isene)
--
--   sqlplus user/pass@db @bench/prior_art.sql
--
-- Needs 23ai/26ai (native UUID(), MLE JavaScript) and, next to UUID_V7:
--   GENERATE_UUID_V7  PL/SQL function from the Medium article referenced there
--   UUID_V7_RAW       MLE JavaScript call spec over the npm "uuidv7" bundle,
--                     built and loaded exactly as the blog post describes
--
-- Test A is the blog's statement verbatim: CREATE TABLE AS SELECT of one
-- million rows with a DBMS_RANDOM.STRING('a',42) filler column. That filler
-- costs more than any of the generators, so test B repeats the statement
-- without it. Rounds are interleaved; the average of c_rounds is reported.

WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF

DECLARE
  c_rounds CONSTANT PLS_INTEGER := 3;
  c_rows   CONSTANT PLS_INTEGER := 1000000;

  TYPE t_names IS TABLE OF VARCHAR2(40);
  TYPE t_secs  IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  l_exprs  t_names := t_names('uuid()', 'generate_uuid_v7()', 'uuid_v7_raw()', 'uuid_v7.generate');
  l_sum    t_secs;
  l_t0     TIMESTAMP WITH TIME ZONE;
  l_iv     INTERVAL DAY TO SECOND;
  l_s      NUMBER;

  PROCEDURE drop_table IS
  BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE bench_prior_art PURGE';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE != -942 THEN RAISE; END IF;
  END;

  PROCEDURE run(p_title IN VARCHAR2, p_filler IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('--- ' || p_title || ', ' || c_rows || ' rows, ' || c_rounds || ' rounds');
    FOR e IN 1 .. l_exprs.COUNT LOOP
      l_sum(e) := 0;
    END LOOP;
    FOR r IN 1 .. c_rounds LOOP
      FOR e IN 1 .. l_exprs.COUNT LOOP
        drop_table;
        l_t0 := SYSTIMESTAMP;
        EXECUTE IMMEDIATE 'CREATE TABLE bench_prior_art AS SELECT ' || l_exprs(e) || ' uuid'
                          || p_filler || ' FROM dual CONNECT BY LEVEL <= ' || c_rows;
        l_iv := SYSTIMESTAMP - l_t0;
        l_s  := EXTRACT(MINUTE FROM l_iv) * 60 + EXTRACT(SECOND FROM l_iv);
        l_sum(e) := l_sum(e) + l_s;
        DBMS_OUTPUT.PUT_LINE('  round ' || r || '  ' || RPAD(l_exprs(e), 22)
                             || LPAD(TO_CHAR(l_s, 'FM990.000'), 8) || ' s');
      END LOOP;
    END LOOP;
    FOR e IN 1 .. l_exprs.COUNT LOOP
      DBMS_OUTPUT.PUT_LINE(RPAD('avg ' || l_exprs(e), 32)
                           || LPAD(TO_CHAR(l_sum(e) / c_rounds, 'FM990.000'), 8) || ' s'
                           || LPAD(TO_CHAR(l_sum(e) / c_rounds / c_rows * 1e6, 'FM99990.00'), 10)
                           || ' us/row');
    END LOOP;
    drop_table;
  END;
BEGIN
  run('A: as published, with DBMS_RANDOM.STRING(''a'',42) filler', ', dbms_random.string(''a'',42) foo');
  run('B: UUID column only', NULL);
END;
/

EXIT SUCCESS
