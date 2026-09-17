-- Self-checking tests for UUID_V7. Exits non-zero on the first failure.
--
--   sqlplus user/pass@db @test/test_uuid_v7.sql
--
-- Creates and drops table UUID_V7_TEST. Takes up to ~60s because one test waits
-- for the wall clock to cross a minute boundary.

WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF

PROMPT == structure, monotonicity, timestamps, text conversion

DECLARE
  c_n       CONSTANT PLS_INTEGER := 200000;
  l_prev    VARCHAR2(32) := '0';
  l_hex     VARCHAR2(32);
  l_id      RAW(16);
  l_before  TIMESTAMP WITH TIME ZONE;
  l_after   TIMESTAMP WITH TIME ZONE;
  l_ts      TIMESTAMP WITH TIME ZONE;
  l_text    VARCHAR2(36);
  l_slack   NUMBER;

  PROCEDURE ok(p_cond IN BOOLEAN, p_what IN VARCHAR2) IS
  BEGIN
    IF p_cond IS NULL OR NOT p_cond THEN
      RAISE_APPLICATION_ERROR(-20999, 'FAILED: ' || p_what);
    END IF;
  END ok;
BEGIN
  -- layout + strictly increasing within the session
  FOR i IN 1 .. c_n LOOP
    l_id  := uuid_v7.generate;
    l_hex := RAWTOHEX(l_id);
    ok(UTL_RAW.LENGTH(l_id) = 16,               'length 16 at #' || i);
    ok(SUBSTR(l_hex, 13, 1) = '7',              'version nibble at #' || i || ': ' || l_hex);
    ok(SUBSTR(l_hex, 17, 1) IN ('8','9','A','B'), 'variant bits at #' || i || ': ' || l_hex);
    -- upper-case hex of equal length: string order = byte order
    -- (the RAW-level check is done in SQL further down)
    ok(l_hex > l_prev, 'monotonic at #' || i || ': ' || l_prev || ' !< ' || l_hex);
    l_prev := l_hex;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('ok   layout + monotonic over ' || c_n || ' values');

  -- embedded timestamp brackets the wall clock. Slack: 1ms for truncation to
  -- milliseconds, 25ms if the package was installed with coarse_clock.
  SELECT CASE WHEN plsql_ccflags LIKE '%uuid_v7_coarse_clock:true%' THEN 0.025 ELSE 0.001 END
    INTO l_slack
    FROM user_plsql_object_settings
   WHERE name = 'UUID_V7' AND type = 'PACKAGE BODY';
  l_before := SYSTIMESTAMP;
  l_ts     := uuid_v7.timestamp_of(uuid_v7.generate);
  l_after  := SYSTIMESTAMP;
  ok(l_ts >= l_before - NUMTODSINTERVAL(l_slack, 'SECOND') AND l_ts <= l_after,
     'timestamp_of within call window: ' || TO_CHAR(l_before, 'HH24:MI:SS.FF6') || ' <= '
     || TO_CHAR(l_ts, 'HH24:MI:SS.FF6 TZR') || ' <= ' || TO_CHAR(l_after, 'HH24:MI:SS.FF6'));
  DBMS_OUTPUT.PUT_LINE('ok   embedded timestamp matches SYSTIMESTAMP');

  -- RFC 9562 appendix A.6 test vector: Tuesday, February 22, 2022 2:22:22.00 PM GMT-05:00
  l_ts := uuid_v7.timestamp_of(HEXTORAW('017F22E279B07CC398C4DC0C0C07398F'));
  ok(l_ts = TIMESTAMP '2022-02-22 19:22:22.000 +00:00', 'RFC 9562 vector timestamp, got ' || l_ts);
  DBMS_OUTPUT.PUT_LINE('ok   RFC 9562 test vector');

  -- text round trip
  l_id   := uuid_v7.generate;
  l_text := uuid_v7.to_string(l_id);
  ok(REGEXP_LIKE(l_text, '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
     'canonical text format: ' || l_text);
  ok(uuid_v7.from_string(l_text) = l_id,          'from_string(to_string(x)) = x');
  ok(uuid_v7.from_string(UPPER(l_text)) = l_id,   'from_string accepts upper case');
  ok(uuid_v7.from_string(RAWTOHEX(l_id)) = l_id,  'from_string accepts bare hex');
  ok(uuid_v7.to_string(NULL) IS NULL AND uuid_v7.from_string(NULL) IS NULL
     AND uuid_v7.timestamp_of(NULL) IS NULL,      'NULL in, NULL out');
  DBMS_OUTPUT.PUT_LINE('ok   to_string / from_string');

  -- bad input is rejected
  BEGIN
    l_text := uuid_v7.to_string(HEXTORAW('00FF'));
    ok(FALSE, 'to_string accepted 2 bytes');
  EXCEPTION WHEN OTHERS THEN ok(SQLCODE = -20700, 'to_string error code, got ' || SQLCODE);
  END;
  BEGIN
    l_id := uuid_v7.from_string('not-a-uuid');
    ok(FALSE, 'from_string accepted garbage');
  EXCEPTION WHEN OTHERS THEN ok(SQLCODE = -20701, 'from_string error code, got ' || SQLCODE);
  END;
  BEGIN
    l_ts := uuid_v7.timestamp_of(SYS_GUID());
    ok(FALSE, 'timestamp_of accepted a non-v7 value');
  EXCEPTION WHEN OTHERS THEN ok(SQLCODE = -20702, 'timestamp_of error code, got ' || SQLCODE);
  END;
  DBMS_OUTPUT.PUT_LINE('ok   input validation');
END;
/

PROMPT == SQL-level ordering and uniqueness (RAW column, as the database sees it)

CREATE TABLE uuid_v7_test (n NUMBER NOT NULL, id RAW(16) NOT NULL);

DECLARE
  TYPE t_ids IS TABLE OF RAW(16) INDEX BY PLS_INTEGER;
  TYPE t_ns  IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
  l_ids        t_ids;
  l_ns         t_ns;
  l_bad        PLS_INTEGER;
  l_distinct   PLS_INTEGER;
  l_tails      PLS_INTEGER;
BEGIN
  -- generated in PL/SQL, array-inserted
  FOR i IN 1 .. 100000 LOOP
    l_ns(i)  := i;
    l_ids(i) := uuid_v7.generate;
  END LOOP;
  FORALL i IN 1 .. l_ids.COUNT
    INSERT INTO uuid_v7_test (n, id) VALUES (l_ns(i), l_ids(i));

  -- generated from SQL, one call per row
  INSERT INTO uuid_v7_test (n, id)
  SELECT 100000 + LEVEL, uuid_v7.generate FROM dual CONNECT BY LEVEL <= 100000;

  SELECT COUNT(*) INTO l_bad
    FROM (SELECT id, LAG(id) OVER (ORDER BY n) AS prev_id FROM uuid_v7_test)
   WHERE id <= prev_id;
  IF l_bad > 0 THEN
    RAISE_APPLICATION_ERROR(-20999, 'FAILED: ' || l_bad || ' rows out of order by RAW comparison');
  END IF;

  SELECT COUNT(DISTINCT id), COUNT(DISTINCT UTL_RAW.SUBSTR(id, 9, 8))
    INTO l_distinct, l_tails FROM uuid_v7_test;
  IF l_distinct != 200000 THEN
    RAISE_APPLICATION_ERROR(-20999, 'FAILED: duplicates, distinct = ' || l_distinct);
  END IF;
  -- each UUID must get its own 62 random bits (catches a stuck random pool)
  IF l_tails != 200000 THEN
    RAISE_APPLICATION_ERROR(-20999, 'FAILED: random tails repeat, distinct = ' || l_tails);
  END IF;
  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('ok   200000 rows: ORDER BY id = generation order, all distinct');
END;
/

DROP TABLE uuid_v7_test PURGE;

PROMPT == minute rollover (waits for the next wall-clock minute)

DECLARE
  l_a    RAW(16);
  l_b    RAW(16);
  l_wait NUMBER;
  l_ts   TIMESTAMP WITH TIME ZONE;
  l_now  TIMESTAMP WITH TIME ZONE;
BEGIN
  l_a    := uuid_v7.generate;
  l_wait := 60 - EXTRACT(SECOND FROM SYSTIMESTAMP) + 0.05;
  DBMS_SESSION.SLEEP(l_wait);
  l_b    := uuid_v7.generate;
  l_now  := SYSTIMESTAMP;
  l_ts   := uuid_v7.timestamp_of(l_b);
  IF NOT (RAWTOHEX(l_b) > RAWTOHEX(l_a)) THEN
    RAISE_APPLICATION_ERROR(-20999, 'FAILED: not monotonic across minute boundary');
  END IF;
  IF NOT (l_ts <= l_now AND l_ts > l_now - INTERVAL '1' SECOND) THEN
    RAISE_APPLICATION_ERROR(-20999, 'FAILED: timestamp after minute rollover: '
      || TO_CHAR(l_ts, 'HH24:MI:SS.FF3 TZR') || ' vs ' || TO_CHAR(l_now, 'HH24:MI:SS.FF3 TZR'));
  END IF;
  IF EXTRACT(MINUTE FROM l_ts) = EXTRACT(MINUTE FROM uuid_v7.timestamp_of(l_a)) THEN
    RAISE_APPLICATION_ERROR(-20999, 'FAILED: test did not cross a minute boundary');
  END IF;
  DBMS_OUTPUT.PUT_LINE('ok   minute rollover (waited ' || ROUND(l_wait, 1) || 's)');
END;
/

PROMPT ALL TESTS PASSED
EXIT SUCCESS
