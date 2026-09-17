-- Benchmark: UUID_V7.GENERATE vs sequence.NEXTVAL vs SYS_GUID() as a key source.
--
--   sqlplus user/pass@db @bench/bench.sql
--
-- Creates and drops BENCH_SEQ, BENCH_NUM, BENCH_RAW. Every INSERT test runs
-- against a freshly truncated table with a primary key index, single session.

WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF

CREATE SEQUENCE bench_seq CACHE 1000;
CREATE TABLE bench_num (id NUMBER  CONSTRAINT bench_num_pk PRIMARY KEY, payload VARCHAR2(30));
CREATE TABLE bench_raw (id RAW(16) CONSTRAINT bench_raw_pk PRIMARY KEY, payload VARCHAR2(30));

DECLARE
  c_calls CONSTANT PLS_INTEGER := 1000000;
  c_rows  CONSTANT PLS_INTEGER := 200000;

  TYPE t_raws IS TABLE OF RAW(16) INDEX BY PLS_INTEGER;
  TYPE t_nums IS TABLE OF NUMBER  INDEX BY PLS_INTEGER;
  l_raws t_raws;
  l_nums t_nums;
  l_raw  RAW(16);
  l_num  NUMBER;
  l_t0   TIMESTAMP;

  PROCEDURE start_timer IS
  BEGIN
    l_t0 := SYSTIMESTAMP;
  END;

  PROCEDURE report(p_what IN VARCHAR2, p_n IN PLS_INTEGER) IS
    l_iv INTERVAL DAY TO SECOND := SYSTIMESTAMP - l_t0;
    l_s  NUMBER := EXTRACT(MINUTE FROM l_iv) * 60 + EXTRACT(SECOND FROM l_iv);
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD(p_what, 46) || LPAD(TO_CHAR(l_s, 'FM990.000'), 8) || ' s'
                         || LPAD(TO_CHAR(l_s / p_n * 1e6, 'FM99990.00'), 10) || ' us/row');
  END;

  PROCEDURE reset IS
  BEGIN
    COMMIT;
    EXECUTE IMMEDIATE 'TRUNCATE TABLE bench_num';
    EXECUTE IMMEDIATE 'TRUNCATE TABLE bench_raw';
  END;
BEGIN
  l_raw := uuid_v7.generate;          -- warm up package state
  l_num := bench_seq.NEXTVAL;

  DBMS_OUTPUT.PUT_LINE('--- key generation only, PL/SQL loop, ' || c_calls || ' calls');
  start_timer;
  FOR i IN 1 .. c_calls LOOP l_num := bench_seq.NEXTVAL; END LOOP;
  report('bench_seq.NEXTVAL (cache 1000)', c_calls);
  start_timer;
  FOR i IN 1 .. c_calls LOOP l_raw := SYS_GUID(); END LOOP;
  report('SYS_GUID()', c_calls);
  start_timer;
  FOR i IN 1 .. c_calls LOOP l_raw := uuid_v7.generate; END LOOP;
  report('uuid_v7.generate', c_calls);

  DBMS_OUTPUT.PUT_LINE('--- row-by-row INSERT ... VALUES in a PL/SQL loop, ' || c_rows || ' rows');
  reset; start_timer;
  FOR i IN 1 .. c_rows LOOP
    INSERT INTO bench_num (id, payload) VALUES (bench_seq.NEXTVAL, 'x');
  END LOOP;
  report('VALUES (bench_seq.NEXTVAL, ...)', c_rows);
  reset; start_timer;
  FOR i IN 1 .. c_rows LOOP
    INSERT INTO bench_raw (id, payload) VALUES (SYS_GUID(), 'x');
  END LOOP;
  report('VALUES (SYS_GUID(), ...)', c_rows);
  reset; start_timer;
  FOR i IN 1 .. c_rows LOOP
    INSERT INTO bench_raw (id, payload) VALUES (uuid_v7.generate, 'x');
  END LOOP;
  report('VALUES (uuid_v7.generate, ...)  [SQL call]', c_rows);
  reset; start_timer;
  FOR i IN 1 .. c_rows LOOP
    l_raw := uuid_v7.generate;
    INSERT INTO bench_raw (id, payload) VALUES (l_raw, 'x');
  END LOOP;
  report('l_id := uuid_v7.generate; VALUES (l_id, ...)', c_rows);

  DBMS_OUTPUT.PUT_LINE('--- FORALL array insert, ' || c_rows || ' rows (ids generated in PL/SQL)');
  reset; start_timer;
  FOR i IN 1 .. c_rows LOOP l_nums(i) := bench_seq.NEXTVAL; END LOOP;
  FORALL i IN 1 .. c_rows INSERT INTO bench_num (id, payload) VALUES (l_nums(i), 'x');
  report('bench_seq.NEXTVAL', c_rows);
  reset; start_timer;
  FOR i IN 1 .. c_rows LOOP l_raws(i) := uuid_v7.generate; END LOOP;
  FORALL i IN 1 .. c_rows INSERT INTO bench_raw (id, payload) VALUES (l_raws(i), 'x');
  report('uuid_v7.generate', c_rows);

  DBMS_OUTPUT.PUT_LINE('--- INSERT ... SELECT, ' || c_rows || ' rows');
  reset; start_timer;
  INSERT INTO bench_num (id, payload)
  SELECT bench_seq.NEXTVAL, 'x' FROM dual CONNECT BY LEVEL <= c_rows;
  report('bench_seq.NEXTVAL', c_rows);
  reset; start_timer;
  INSERT INTO bench_raw (id, payload)
  SELECT SYS_GUID(), 'x' FROM dual CONNECT BY LEVEL <= c_rows;
  report('SYS_GUID()', c_rows);
  reset; start_timer;
  INSERT INTO bench_raw (id, payload)
  SELECT uuid_v7.generate, 'x' FROM dual CONNECT BY LEVEL <= c_rows;
  report('uuid_v7.generate', c_rows);
  reset;
END;
/

DROP TABLE bench_raw PURGE;
DROP TABLE bench_num PURGE;
DROP SEQUENCE bench_seq;
EXIT SUCCESS
