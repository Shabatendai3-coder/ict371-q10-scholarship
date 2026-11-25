-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- Student: Patience Shaba (202409214) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path TO q10, public;

-- (a) Tables and seed data -------------------------------------------------------------------
CREATE TABLE students (
  student_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
  application_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id         INTEGER NOT NULL REFERENCES students(student_id),
  age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
  audit_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  application_id INTEGER NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10) NOT NULL,
  new_status     VARCHAR(10) NOT NULL,
  changed_at     TIMESTAMP NOT NULL DEFAULT now()
);
INSERT INTO students (student_number, full_name) VALUES
 ('SC2026001', 'Mercy Daka'), ('SC2026002', 'Noel Kapambwe'), ('SC2026003', 'Olivia Sichone');
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
 (1, 20, 2000.00, 80.00, '2026-11-01', 'PENDING'),   -- clearly qualifies
 (1, 18, 3000.00, 70.00, '2026-11-03', 'PENDING'),   -- lower boundaries: qualifies
 (2, 25, 2999.99, 70.00, '2026-11-05', 'PENDING'),   -- age upper boundary: qualifies
 (2, 26, 1000.00, 90.00, '2026-11-08', 'PENDING'),   -- too old
 (3, 22, 3000.01, 85.00, '2026-11-10', 'PENDING'),   -- income just above limit
 (3, 19, 1500.00, 69.99, '2026-11-12', 'PENDING');   -- mark just below limit

-- (b) Function -----------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark are all required.';
  END IF;
  IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive.'; END IF;
  IF p_income < 0 THEN RAISE EXCEPTION 'Income cannot be negative.'; END IF;
  IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be between 0 and 100.'; END IF;
  RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END; $$;

-- (c) Procedure ------------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql SET search_path = q10, public AS $$
DECLARE v_age INTEGER; v_income NUMERIC; v_mark NUMERIC; v_status VARCHAR(10); v_ok BOOLEAN;
BEGIN
  SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application % does not exist.', p_application_id;
  END IF;
  IF v_status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % has already been assessed (%).', p_application_id, v_status;
  END IF;
  v_ok := fn_scholarship_eligible(v_age, v_income, v_mark);
  UPDATE applications
     SET status = CASE WHEN v_ok THEN 'APPROVED' ELSE 'REJECTED' END
   WHERE application_id = p_application_id;
END; $$;

-- (d) Trigger -----------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_decision_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
      VALUES (OLD.application_id, OLD.status, NEW.status, now());
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_applications_audit AFTER UPDATE ON applications FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION fn_trg_decision_audit();

-- Tests
SELECT fn_scholarship_eligible(20, 2000, 80) AS yes, fn_scholarship_eligible(26, 1000, 90) AS too_old,
       fn_scholarship_eligible(18, 3000, 70) AS boundary_low, fn_scholarship_eligible(25, 3000, 70) AS boundary_high;
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1, 1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative income): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 100, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (age): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (mark): %', SQLERRM; END $$;
CALL pr_assess_application(1);
DO $$ BEGIN CALL pr_assess_application(1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already assessed): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown): %', SQLERRM; END $$;
UPDATE applications SET status = status WHERE application_id = 1;    -- unchanged: no audit row
SELECT * FROM decision_audit ORDER BY audit_id;                       -- exactly one row

-- (e) View: APPROVED only, income omitted ------------------------------------------------------------------------
CREATE VIEW v_approved_applicants AS
  SELECT s.student_number, s.full_name, a.average_mark, a.status
  FROM applications a JOIN students s ON s.student_id = a.student_id
  WHERE a.status = 'APPROVED';

-- (f) Index ----------------------------------------------------------------------------------------------------------
-- Equality on status then a range on submitted_on, so one range scan returns the applications in
-- one status for a date window already ordered by date.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;
SET enable_seqscan = off;   -- tiny table: forces the plan to show the index
EXPLAIN SELECT application_id, student_id, submitted_on FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql SET search_path = q10, public AS $$
DECLARE rec RECORD;
BEGIN
  FOR rec IN SELECT application_id FROM applications
              WHERE status = 'PENDING' ORDER BY application_id     -- completed ones are skipped
  LOOP
    CALL pr_assess_application(rec.application_id);
  END LOOP;
END; $$;
CALL pr_assess_pending();                       -- assesses the 5 still-pending applications
CALL pr_assess_pending();                       -- rerun: nothing pending, no new audit rows
SELECT application_id, status FROM applications ORDER BY 1;
SELECT COUNT(*) AS audit_rows FROM decision_audit;                    -- 6, one per decision
SELECT * FROM v_approved_applicants ORDER BY student_number;          -- queried after assessment

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q10_assess_pending', '0 8 * * 1', $$CALL q10.pr_assess_pending()$$);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q10_assess_pending';
