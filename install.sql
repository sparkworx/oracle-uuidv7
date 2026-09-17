-- Installs the UUID_V7 package into the current schema.
--
--   sqlplus user/pass@db @install.sql
--
-- Prerequisite (once, as a privileged user):
--   GRANT EXECUTE ON SYS.DBMS_CRYPTO TO <schema>;
-- If that grant is not obtainable, install the DBMS_RANDOM-based variant:
--   sqlplus user/pass@db @install.sql no_crypto

WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET VERIFY OFF FEEDBACK ON

-- optional first argument, defaulting to "crypto"
COLUMN 1 NEW_VALUE 1 NOPRINT
SET TERMOUT OFF
SELECT NULL AS "1" FROM dual WHERE 1 = 0;
SET TERMOUT ON
COLUMN ccflag NEW_VALUE ccflag NOPRINT
SELECT CASE LOWER('&1') WHEN 'no_crypto' THEN 'true' ELSE 'false' END AS ccflag FROM dual;

ALTER SESSION SET plsql_code_type = NATIVE;
ALTER SESSION SET plsql_optimize_level = 3;
ALTER SESSION SET plsql_ccflags = 'uuid_v7_no_crypto:&ccflag';

@@src/uuid_v7.pks
SHOW ERRORS PACKAGE uuid_v7
@@src/uuid_v7.pkb
SHOW ERRORS PACKAGE BODY uuid_v7

-- fail the install if either unit did not compile
DECLARE
  l_invalid PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_invalid
    FROM user_objects
   WHERE object_name = 'UUID_V7' AND status != 'VALID';
  IF l_invalid > 0 THEN
    RAISE_APPLICATION_ERROR(-20000, 'UUID_V7 did not compile - see errors above');
  END IF;
END;
/

SELECT uuid_v7.to_string(uuid_v7.generate) AS sample_uuid_v7 FROM dual;
