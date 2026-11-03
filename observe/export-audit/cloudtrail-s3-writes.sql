-- Purpose: query the S3 data events that cloudtrail-s3-data-events.sh records, to see every object written
--   to the export bucket, by whom and when.
-- Post section: "What the agent keeps: database-side exports and copies" (CloudTrail S3 data events for bucket writes).
-- Prerequisites: Amazon Athena, an Athena database (<audit_db>), a query result location, and read access to the
--   trail bucket. The table uses partition projection, so no partitions need loading.
-- Placeholders: <audit_db>, <trail-bucket>, <account-id>, <region>, <projection-start-yyyy/MM/dd> (first day of the trail's data), <unload-bucket>, <yyyy/MM/dd>, <start-utc>, <end-utc>.
-- Reading the result: UNLOAD writes are made by the IAM role that Redshift assumes (the IAM_ROLE in the UNLOAD,
--   shown in role_arn), not by the agent's role. Match each write to the agent's statement in
--   SYS_UNLOAD_HISTORY (export-audit.sql) by S3 prefix (unloaded_location) and time.

-- 1. The database and table (run once)
CREATE DATABASE IF NOT EXISTS <audit_db>;
CREATE EXTERNAL TABLE <audit_db>.cloudtrail_s3_writes (
  eventversion STRING,
  useridentity STRUCT<
    type: STRING, principalid: STRING, arn: STRING, accountid: STRING, invokedby: STRING,
    accesskeyid: STRING, username: STRING,
    sessioncontext: STRUCT<
      attributes: STRUCT<mfaauthenticated: STRING, creationdate: STRING>,
      sessionissuer: STRUCT<type: STRING, principalid: STRING, arn: STRING, accountid: STRING, username: STRING>,
      sourceidentity: STRING>>,
  eventtime STRING,
  eventsource STRING,
  eventname STRING,
  awsregion STRING,
  sourceipaddress STRING,
  useragent STRING,
  errorcode STRING,
  errormessage STRING,
  requestparameters STRING,
  responseelements STRING,
  additionaleventdata STRING,
  requestid STRING,
  eventid STRING,
  readonly STRING,
  resources ARRAY<STRUCT<arn: STRING, accountid: STRING, type: STRING>>,
  eventtype STRING,
  recipientaccountid STRING,
  sharedeventid STRING,
  vpcendpointid STRING,
  eventcategory STRING
)
PARTITIONED BY (`timestamp` STRING)
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
STORED AS INPUTFORMAT 'com.amazon.emr.cloudtrail.CloudTrailInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://<trail-bucket>/AWSLogs/<account-id>/CloudTrail/<region>/'
TBLPROPERTIES (
  'projection.enabled' = 'true',
  'projection.timestamp.type' = 'date',
  'projection.timestamp.format' = 'yyyy/MM/dd',
  'projection.timestamp.range' = '<projection-start-yyyy/MM/dd>,NOW',
  'projection.timestamp.interval' = '1',
  'projection.timestamp.interval.unit' = 'DAYS',
  'storage.location.template' = 's3://<trail-bucket>/AWSLogs/<account-id>/CloudTrail/<region>/${timestamp}'
);

-- 2. Object writes to the export bucket in a time window
SELECT eventtime, eventname,
       useridentity.arn AS caller_arn,
       useridentity.sessioncontext.sessionissuer.arn AS role_arn,
       useridentity.invokedby AS invoked_by,
       sourceipaddress, useragent,
       json_extract_scalar(requestparameters, '$.key') AS object_key,
       errorcode
FROM <audit_db>.cloudtrail_s3_writes
WHERE "timestamp" >= '<yyyy/MM/dd>'
  AND eventsource = 's3.amazonaws.com'
  AND eventname IN ('PutObject', 'CreateMultipartUpload', 'UploadPart', 'CompleteMultipartUpload', 'CopyObject')
  AND json_extract_scalar(requestparameters, '$.bucketName') = '<unload-bucket>'
  AND eventtime BETWEEN '<start-utc>' AND '<end-utc>'
ORDER BY eventtime;
