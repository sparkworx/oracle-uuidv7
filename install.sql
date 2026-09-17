-- Installs the UUID_V7 package into the current schema.
--
--   sqlplus user/pass@db @install.sql [no_crypto] [coarse_clock]
--
-- Prerequisite (once, as a privileged user):
--   GRANT EXECUTE ON SYS.DBMS_CRYPTO TO <schema>;
--
-- Options (any order):
--   no_crypto     take random bits from DBMS_RANDOM instead of DBMS_CRYPTO, for
--                 schemas that cannot get the grant above. Not a CSPRNG.
--   coarse_clock  read SYSTIMESTAMP at most once per 10ms and count up in
--                 between. ~40% less CPU per UUID; embedded timestamps may lag
--                 the wall clock by up to 10ms. Ordering guarantees unchanged.

WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET VERIFY OFF FEEDBACK ON

-- make &1 and &2 optional
COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
SET TERMOUT OFF
SELECT NULL AS "1", NULL AS "2" FROM dual WHERE 1 = 0;
SET TERMOUT ON

COLUMN ccflags NEW_VALUE ccflags NOPRINT
SELECT 'uuid_v7_no_crypto:'
       || CASE WHEN INSTR(LOWER(' &1 &2 '), ' no_crypto ') > 0 THEN 'true' ELSE 'false' END
       || ',uuid_v7_coarse_clock:'
       || CASE WHEN INSTR(LOWER(' &1 &2 '), ' coarse_clock ') > 0 THEN 'true' ELSE 'false' END
       AS ccflags
  FROM dual;

ALTER SESSION SET plsql_code_type = NATIVE;
ALTER SESSION SET plsql_optimize_level = 3;
ALTER SESSION SET plsql_ccflags = '&ccflags';

@@src/uuid_v7.pks
SHOW ERRORS PACKAGE uuid_v7
@@src/uuid_v7.pkb
SHOW ERRORS PACKAGE BODY uuid_v7

-- Native compilation can fail for reasons that have nothing to do with the
-- code, e.g. ORA-00600 [pesldl03_MMap] when /dev/shm is mounted noexec (Docker
-- default, hardened hosts). Retry interpreted before giving up; most of the
-- run time is inside C built-ins either way.
SET SERVEROUTPUT ON
DECLARE
  FUNCTION invalid_units RETURN PLS_INTEGER IS
    l_invalid PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO l_invalid
      FROM user_objects
     WHERE object_name = 'UUID_V7' AND status != 'VALID';
    RETURN l_invalid;
  END;
BEGIN
  IF invalid_units > 0 THEN
    BEGIN
      EXECUTE IMMEDIATE
        'ALTER PACKAGE uuid_v7 COMPILE PLSQL_CODE_TYPE = INTERPRETED REUSE SETTINGS';
    EXCEPTION
      WHEN OTHERS THEN NULL;   -- compile errors surface through invalid_units below
    END;
    IF invalid_units > 0 THEN
      RAISE_APPLICATION_ERROR(-20000, 'UUID_V7 did not compile - see errors above');
    END IF;
    DBMS_OUTPUT.PUT_LINE('NOTE: native compilation failed on this host (see above); '
                         || 'UUID_V7 was compiled INTERPRETED instead.');
  END IF;
END;
/

PROMPT Installed UUID_V7 with &ccflags
SELECT uuid_v7.to_string(uuid_v7.generate) AS sample_uuid_v7 FROM dual;
