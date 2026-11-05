-- Act pattern: one scoped write tool, with human approval above a threshold.
--
-- Part 1: run as the procedure owner, a non-superuser that holds the refund_owner role, has
-- USAGE and CREATE on schema support, USAGE on schema sales, and SELECT on sales.orders. The owner creates and so
-- owns support.refunds. Use a non-superuser: a superuser owner bypasses RLS, which hides why the
-- rls_all_orders policy in part 2 is needed.

CREATE TABLE support.refunds (
  refund_id    BIGINT IDENTITY(1,1),
  order_id     BIGINT,
  amount       DECIMAL(10,2),
  requested_by VARCHAR(128),
  requested_at TIMESTAMP,
  status       VARCHAR(32),     -- approved or pending_approval
  approved_by  VARCHAR(128),    -- NULL when approved automatically
  approved_at  TIMESTAMP
);

-- The agent's only write: validates the request against what is left to refund on the order,
-- approves small refunds, and queues larger ones
CREATE OR REPLACE PROCEDURE support.refund_order(p_order_id BIGINT, p_amount DECIMAL(10,2))
AS $$
DECLARE v_total DECIMAL(10,2); v_left DECIMAL(10,2); v_caller VARCHAR(128); v_status VARCHAR(32);
BEGIN
  v_caller := SESSION_USER;  -- assign first: SESSION_USER can't be used directly in an INSERT
  LOCK support.refunds;  -- one refund at a time, so concurrent calls can't overspend an order
  SELECT total_amount INTO v_total FROM sales.orders WHERE order_id = p_order_id;
  IF v_total IS NULL THEN RAISE EXCEPTION 'Order % not found', p_order_id; END IF;
  SELECT v_total - COALESCE(SUM(amount), 0) INTO v_left FROM support.refunds
  WHERE order_id = p_order_id AND status IN ('approved', 'pending_approval');
  IF p_amount <= 0 OR p_amount > LEAST(v_left, 500.00) THEN
    RAISE EXCEPTION 'Refund of % is outside the allowed range for order %', p_amount, p_order_id;
  END IF;
  IF p_amount <= 100.00 THEN v_status := 'approved'; ELSE v_status := 'pending_approval'; END IF;
  INSERT INTO support.refunds (order_id, amount, requested_by, requested_at, status)
  VALUES (p_order_id, p_amount, v_caller, GETDATE(), v_status);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = support, sales;

-- The human step: only refund_approvers can run it, and nobody can approve their own request
CREATE OR REPLACE PROCEDURE support.approve_refund(p_refund_id BIGINT)
AS $$
DECLARE v_status VARCHAR(32); v_requester VARCHAR(128); v_caller VARCHAR(128);
BEGIN
  v_caller := SESSION_USER;
  SELECT status, requested_by INTO v_status, v_requester
  FROM support.refunds WHERE refund_id = p_refund_id;
  IF v_status IS NULL OR v_status <> 'pending_approval' THEN
    RAISE EXCEPTION 'Refund % is not pending approval', p_refund_id;
  END IF;
  IF v_requester = v_caller THEN
    RAISE EXCEPTION 'A refund cannot be approved by its requester';
  END IF;
  UPDATE support.refunds
  SET status = 'approved', approved_by = v_caller, approved_at = GETDATE()
  WHERE refund_id = p_refund_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = support;

-- Defensive: Redshift grants EXECUTE on a new procedure only to its owner and superusers
REVOKE EXECUTE ON PROCEDURE support.refund_order(BIGINT, DECIMAL(10,2)) FROM PUBLIC;
REVOKE EXECUTE ON PROCEDURE support.approve_refund(BIGINT) FROM PUBLIC;

-- Part 2: run as an administrator (a superuser, or a user with the sys:secadmin role for the RLS lines).
-- The agent can request; only people can approve; neither can touch the tables directly
CREATE ROLE agent_refunds;
CREATE ROLE refund_approvers;
GRANT USAGE ON SCHEMA support TO ROLE agent_refunds;
GRANT USAGE ON SCHEMA support TO ROLE refund_approvers;
GRANT EXECUTE ON PROCEDURE support.refund_order(BIGINT, DECIMAL(10,2)) TO ROLE agent_refunds;
GRANT EXECUTE ON PROCEDURE support.approve_refund(BIGINT) TO ROLE refund_approvers;
GRANT ROLE agent_refunds TO "IAMR:agent-support-actions";  -- after the action identity's first sign-in

-- The procedure reads sales.orders with its owner's RLS policies (the data layer section turns RLS on),
-- so let a role that the owner holds (refund_owner here) see every order
CREATE RLS POLICY rls_all_orders WITH (order_id BIGINT) USING (true);
ATTACH RLS POLICY rls_all_orders ON sales.orders TO ROLE refund_owner;
