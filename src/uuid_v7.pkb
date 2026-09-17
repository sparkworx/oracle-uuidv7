CREATE OR REPLACE PACKAGE BODY uuid_v7 AS

  c_2p28      CONSTANT NUMBER      := 268435456;
  c_buf_bytes CONSTANT PLS_INTEGER := 2000;   -- 250 UUIDs of randomness per refill
  c_epoch     CONSTANT TIMESTAMP   := TIMESTAMP '1970-01-01 00:00:00';

  -- 60-bit timestamp of the last UUID issued by this session:
  -- floor(unix epoch milliseconds * 4096).
  g_last      NUMBER := 0;

  -- Converting SYSTIMESTAMP to epoch time is the expensive part of a call, so
  -- the conversion is done once per wall-clock minute. While SYSTIMESTAMP stays
  -- inside [g_min_lo, g_min_hi) only its SECOND field has to be extracted.
  g_min_lo    TIMESTAMP WITH TIME ZONE;
  g_min_hi    TIMESTAMP WITH TIME ZONE;
  g_min_base  NUMBER;                         -- epoch ms of g_min_lo, * 4096

  -- Pool of random bytes with the variant bits (10xx xxxx) already stamped on
  -- every 8th byte, consumed 8 bytes per UUID.
  g_rnd       RAW(2000);
  g_pos       PLS_INTEGER := c_buf_bytes + 1;
  g_and_mask  CONSTANT RAW(2000) := UTL_RAW.COPIES(HEXTORAW('3FFFFFFFFFFFFFFF'), c_buf_bytes / 8);
  g_or_mask   CONSTANT RAW(2000) := UTL_RAW.COPIES(HEXTORAW('8000000000000000'), c_buf_bytes / 8);

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

  PROCEDURE refill_random IS
  BEGIN
$IF $$uuid_v7_no_crypto $THEN
    -- Fallback for schemas without EXECUTE on DBMS_CRYPTO. Not a CSPRNG.
    g_rnd := NULL;
    FOR i IN 1 .. c_buf_bytes / 4 LOOP
      g_rnd := UTL_RAW.CONCAT(g_rnd, UTL_RAW.CAST_FROM_BINARY_INTEGER(DBMS_RANDOM.RANDOM));
    END LOOP;
    g_rnd := UTL_RAW.BIT_OR(UTL_RAW.BIT_AND(g_rnd, g_and_mask), g_or_mask);
$ELSE
    g_rnd := UTL_RAW.BIT_OR(UTL_RAW.BIT_AND(DBMS_CRYPTO.RANDOMBYTES(c_buf_bytes), g_and_mask),
                            g_or_mask);
$END
    g_pos := 1;
  END refill_random;

  FUNCTION generate RETURN RAW PARALLEL_ENABLE IS
    l_now  TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
    l_t    NUMBER;
    l_w1   PLS_INTEGER;   -- bytes 0-3: unix_ts_ms bits 47..16
    l_w2   PLS_INTEGER;   -- bytes 4-7: unix_ts_ms bits 15..0, version, fraction
    l_rem  PLS_INTEGER;
    l_frac PLS_INTEGER;
    l_lo16 PLS_INTEGER;
    l_pos  PLS_INTEGER;
  BEGIN
    IF l_now >= g_min_hi OR l_now < g_min_lo THEN
      sync_minute(l_now);
    END IF;

    l_t := g_min_base + TRUNC(EXTRACT(SECOND FROM l_now) * 4096000);

    -- Same clock reading as last time, or the clock stepped backwards: keep
    -- counting up from the last value so the session stays monotonic.
    IF l_t <= g_last THEN
      l_t := g_last + 1;
    END IF;
    g_last := l_t;

    l_w1   := TRUNC(l_t / c_2p28);
    l_rem  := l_t - l_w1 * c_2p28;
    l_frac := BITAND(l_rem, 4095);
    l_lo16 := (l_rem - l_frac) / 4096;
    -- PLS_INTEGER is signed 32-bit: fold the top bit into the sign
    IF l_lo16 > 32767 THEN
      l_lo16 := l_lo16 - 65536;
    END IF;
    l_w2 := l_lo16 * 65536 + 28672 + l_frac;   -- 28672 = 0x7000, the version nibble

    IF g_pos > c_buf_bytes THEN
      refill_random;
    END IF;
    l_pos := g_pos;
    g_pos := g_pos + 8;

    RETURN UTL_RAW.CONCAT(UTL_RAW.CAST_FROM_BINARY_INTEGER(l_w1, UTL_RAW.BIG_ENDIAN),
                          UTL_RAW.CAST_FROM_BINARY_INTEGER(l_w2, UTL_RAW.BIG_ENDIAN),
                          UTL_RAW.SUBSTR(g_rnd, l_pos, 8));
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
END uuid_v7;
/
