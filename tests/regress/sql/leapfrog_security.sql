-- leapfrog_security: under row-level security only a leakproof clause becomes a stream's condition
-- One transaction: a role is cluster-wide, and the rollback leaves nothing behind.
BEGIN;
SET LOCAL enable_seqscan = off;

CREATE ROLE lf_security_reader;
CREATE TABLE lf_security (
	id bigint NOT NULL,
	tenant_id integer NOT NULL,
	category_id bigint NOT NULL,
	price numeric NOT NULL
);
INSERT INTO lf_security
SELECT g, g % 2, g % 10, g % 7 FROM generate_series(1, 20000) g;
CREATE INDEX lf_security_tenant ON lf_security (tenant_id, id);
CREATE INDEX lf_security_category ON lf_security (category_id, id);
CREATE INDEX lf_security_price ON lf_security (price, id);
ANALYZE lf_security;
ALTER TABLE lf_security ENABLE ROW LEVEL SECURITY;
CREATE POLICY lf_security_tenant_only ON lf_security USING (tenant_id = 1);
GRANT SELECT ON lf_security TO lf_security_reader;

-- what the test depends on: bigint = is leakproof, numeric = is not
SELECT oprname, oprleft::regtype, p.proleakproof
FROM pg_operator o JOIN pg_proc p ON p.oid = o.oprcode
WHERE oprname = '=' AND oprleft = oprright AND oprleft IN ('bigint'::regtype, 'numeric'::regtype)
ORDER BY 2;

-- As the owner, a superuser here, the policy does not apply: numeric = is a stream.
SELECT * FROM lf_plan($$
SELECT * FROM lf_security WHERE category_id = 3 AND price = 3 ORDER BY id LIMIT 5 $$);

SET LOCAL ROLE lf_security_reader;

-- leakproof: a stream, together with the policy's own condition
SELECT * FROM lf_plan($$
SELECT * FROM lf_security WHERE category_id = 3 ORDER BY id LIMIT 5 $$);
SELECT lf_check($$ SELECT * FROM lf_security WHERE category_id = 3 ORDER BY id LIMIT 5 $$);

-- not leakproof: in the Filter, after the policy
SELECT * FROM lf_plan($$
SELECT * FROM lf_security WHERE category_id = 3 AND price = 3 ORDER BY id LIMIT 5 $$);
SELECT lf_check($$ SELECT * FROM lf_security WHERE category_id = 3 AND price = 3 ORDER BY id LIMIT 5 $$);

-- the only other condition is not leakproof: no second stream, no node
SELECT * FROM lf_plan($$
SELECT * FROM lf_security WHERE price = 3 ORDER BY id LIMIT 5 $$);
SELECT lf_check($$ SELECT * FROM lf_security WHERE price = 3 ORDER BY id LIMIT 5 $$);

ROLLBACK;
