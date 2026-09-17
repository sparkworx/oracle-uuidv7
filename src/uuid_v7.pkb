CREATE OR REPLACE PACKAGE BODY uuid_v7 AS
  -- SPDX-License-Identifier: MIT
  -- Copyright (c) 2026 Ian Woodbury
  /*
   * Performance notes (measured, see README): UTL_RAW calls cost 0.3-0.5us each
   * while native HEXTORAW / SUBSTRB / || cost a few hundredths, so the value is
   * assembled as a 32-character hex string and converted once. SUBSTRB, not
   * SUBSTR: in a multi-byte database character set (AL32UTF8) SUBSTR has to
   * scan the string from the start to find a character offset.
   */

  c_epoch     CONSTANT TIMESTAMP    := TIMESTAMP '1970-01-01 00:00:00';
  c_hex       CONSTANT VARCHAR2(16) := '0123456789ABCDEF';
  c_pool_len  CONSTANT PLS_INTEGER  := 4000;   -- hex chars: 2000 random bytes = 250 UUIDs

  -- 60-bit timestamp of the last UUID issued by this session:
  -- floor(unix epoch milliseconds * 4096).
  g_last      NUMBER := 0;

  -- Converting SYSTIMESTAMP to epoch time is expensive, so it is done once per
  -- wall-clock minute. While SYSTIMESTAMP stays inside [g_min_lo, g_min_hi)
  -- only its SECOND field has to be extracted.
  g_min_lo    TIMESTAMP WITH TIME ZONE;
  g_min_hi    TIMESTAMP WITH TIME ZONE;
  g_min_base  NUMBER;                          -- epoch ms of g_min_lo, * 4096

  -- Hex of the 48-bit millisecond field plus the version digit, recomputed
  -- only when the millisecond changes.
  g_ms        NUMBER := -1;
  g_ms_hex    VARCHAR2(13);

  g_byte_hex  VARCHAR2(512);                   -- '000102..FF', 2-digit hex lookup

  -- Pool of random hex with the variant bits (10xx) already stamped on every
  -- 8th byte, consumed 16 characters per UUID.
  g_rnd       VARCHAR2(4000);
  g_pos       PLS_INTEGER := c_pool_len + 1;
  g_and_mask  CONSTANT RAW(2000) := UTL_RAW.COPIES(HEXTORAW('3FFFFFFFFFFFFFFF'), c_pool_len / 16);
  g_or_mask   CONSTANT RAW(2000) := UTL_RAW.COPIES(HEXTORAW('8000000000000000'), c_pool_len / 16);

$IF $$uuid_v7_coarse_clock $THEN
  g_tick      PLS_INTEGER := -1;               -- last DBMS_UTILITY.GET_TIME seen
$END

  PROCEDURE sync_minute(p_now IN TIMESTAMP WITH TIME ZONE) IS
    l_since_epoch INTERVAL DAY(9) TO SECOND(9);
  BEGIN
    g_min_lo      := p_now - NUMTODSINTERVAL(EXTRACT(SECOND FROM p_now), 'SECOND');
    g_min_hi      := g_min_lo + NUMTODSINTERVAL(1, 'MINUTE');
    l_since_epoch := SYS_EXTRACT_UTC(g_min_lo) - c_epoch;
    g_min_base    := (  EXTRACT(DAY    FROM l_since_epoch) * 1440
                      + EXTRACT(HOUR   FROM l_since_epoch) * 60
                      + EXTRACT(MINUTE FROM l_since_epoch)) * 60000 * 4096;
  END sync_minute;

  -- Wall clock as floor(epoch milliseconds * 4096).
  FUNCTION clock_now RETURN NUMBER IS
    l_now TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
  BEGIN
    IF l_now >= g_min_hi OR l_now < g_min_lo THEN
      sync_minute(l_now);
    END IF;
    RETURN g_min_base + TRUNC(EXTRACT(SECOND FROM l_now) * 4096000);
  END clock_now;

  PROCEDURE refill_random IS
    l_bytes RAW(2000);
  BEGIN
$IF $$uuid_v7_no_crypto $THEN
    -- Fallback for schemas without EXECUTE on DBMS_CRYPTO. Not a CSPRNG.
    FOR i IN 1 .. c_pool_len / 8 LOOP
      l_bytes := UTL_RAW.CONCAT(l_bytes, UTL_RAW.CAST_FROM_BINARY_INTEGER(DBMS_RANDOM.RANDOM));
    END LOOP;
$ELSE
    l_bytes := DBMS_CRYPTO.RANDOMBYTES(c_pool_len / 2);
$END
    g_rnd := RAWTOHEX(UTL_RAW.BIT_OR(UTL_RAW.BIT_AND(l_bytes, g_and_mask), g_or_mask));
    g_pos := 1;
  END refill_random;

  FUNCTION generate RETURN RAW PARALLEL_ENABLE IS
    l_t    NUMBER;
    l_ms   NUMBER;
    l_frac PLS_INTEGER;
    l_pos  PLS_INTEGER;
$IF $$uuid_v7_coarse_clock $THEN
    l_tick PLS_INTEGER := DBMS_UTILITY.GET_TIME;
$END
  BEGIN
$IF $$uuid_v7_coarse_clock $THEN
    -- SYSTIMESTAMP is the single most expensive step. In this build it is only
    -- read when the (cheap) centisecond tick counter has moved; in between,
    -- values count up from the last one, so embedded times can lag by <= 10ms.
    IF l_tick = g_tick THEN
      l_t := 0;
    ELSE
      g_tick := l_tick;
      PRAGMA INLINE (clock_now, 'YES');
      l_t := clock_now;
    END IF;
$ELSE
    PRAGMA INLINE (clock_now, 'YES');
    l_t := clock_now;
$END

    -- Same clock reading as last time, or the clock stepped backwards: keep
    -- counting up from the last value so the session stays strictly monotonic.
    IF l_t <= g_last THEN
      l_t := g_last + 1;
    END IF;
    g_last := l_t;

    l_ms   := TRUNC(l_t / 4096);
    l_frac := l_t - l_ms * 4096;
    IF l_ms != g_ms THEN
      g_ms     := l_ms;
      g_ms_hex := TO_CHAR(l_ms, 'FM0XXXXXXXXXXX') || '7';
    END IF;

    IF g_pos > c_pool_len THEN
      refill_random;
    END IF;
    l_pos := g_pos;
    g_pos := g_pos + 16;

    RETURN HEXTORAW(   g_ms_hex
                    || SUBSTRB(c_hex, TRUNC(l_frac / 256) + 1, 1)
                    || SUBSTRB(g_byte_hex, BITAND(l_frac, 255) * 2 + 1, 2)
                    || SUBSTRB(g_rnd, l_pos, 16));
  END generate;

  FUNCTION to_string(p_uuid IN RAW) RETURN VARCHAR2 DETERMINISTIC PARALLEL_ENABLE IS
    l_hex VARCHAR2(32);
  BEGIN
    IF p_uuid IS NULL THEN
      RETURN NULL;
    ELSIF UTL_RAW.LENGTH(p_uuid) != 16 THEN
      RAISE_APPLICATION_ERROR(-20700, 'uuid_v7.to_string: expected 16 bytes, got '
                                      || UTL_RAW.LENGTH(p_uuid));
    END IF;
    l_hex := LOWER(RAWTOHEX(p_uuid));
    RETURN SUBSTR(l_hex, 1, 8)  || '-' || SUBSTR(l_hex, 9, 4)  || '-' ||
           SUBSTR(l_hex, 13, 4) || '-' || SUBSTR(l_hex, 17, 4) || '-' ||
           SUBSTR(l_hex, 21, 12);
  END to_string;

  FUNCTION from_string(p_text IN VARCHAR2) RETURN RAW DETERMINISTIC PARALLEL_ENABLE IS
    l_hex VARCHAR2(64) := REPLACE(TRIM(p_text), '-');
  BEGIN
    IF l_hex IS NULL THEN
      RETURN NULL;
    ELSIF LENGTH(l_hex) != 32 THEN
      RAISE_APPLICATION_ERROR(-20701, 'uuid_v7.from_string: expected 32 hex digits');
    END IF;
    RETURN HEXTORAW(l_hex);
  END from_string;

  FUNCTION timestamp_of(p_uuid IN RAW) RETURN TIMESTAMP WITH TIME ZONE
    DETERMINISTIC PARALLEL_ENABLE IS
    l_hex VARCHAR2(32);
  BEGIN
    IF p_uuid IS NULL THEN
      RETURN NULL;
    END IF;
    l_hex := RAWTOHEX(p_uuid);
    IF LENGTH(l_hex) != 32 OR SUBSTR(l_hex, 13, 1) != '7' THEN
      RAISE_APPLICATION_ERROR(-20702, 'uuid_v7.timestamp_of: not a version 7 UUID');
    END IF;
    RETURN TIMESTAMP '1970-01-01 00:00:00 +00:00'
           + NUMTODSINTERVAL(TO_NUMBER(SUBSTR(l_hex, 1, 12), 'XXXXXXXXXXXX') / 1000, 'SECOND');
  END timestamp_of;

BEGIN
  sync_minute(SYSTIMESTAMP);
  FOR i IN 0 .. 255 LOOP
    g_byte_hex := g_byte_hex || TO_CHAR(i, 'FM0X');
  END LOOP;
END uuid_v7;
/
