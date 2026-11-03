-- Exports: only approved pipeline roles can use IAM roles for UNLOAD
-- (this also revokes COPY and CREATE MODEL use, so grant back what each pipeline needs)
REVOKE ASSUMEROLE ON ALL FROM PUBLIC FOR ALL;
GRANT ASSUMEROLE ON 'arn:aws:iam::111122223333:role/etl-unload'
  TO ROLE etl_pipeline FOR UNLOAD;
 
-- Copies: nobody creates tables in the public schema by default
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
