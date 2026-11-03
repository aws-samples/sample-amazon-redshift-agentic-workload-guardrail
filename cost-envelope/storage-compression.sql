-- Iceberg: zstd is the default; set the codec explicitly to make the choice visible
ALTER TABLE "agent-lake@s3tablescatalog".sales.orders
SET TABLE PROPERTIES ('compression_type'='zstd');   -- or 'snappy' for speed over size
 
-- Managed storage: estimated savings per column for a table
ANALYZE COMPRESSION sales.orders;
