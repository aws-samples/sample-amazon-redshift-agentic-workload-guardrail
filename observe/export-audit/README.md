# Export audit: what left Redshift

Two views of every export: what agent users ran, from SYS_UNLOAD_HISTORY and SYS_QUERY_HISTORY, and which objects were written to the export bucket, from AWS CloudTrail S3 data events queried in Amazon Athena. Together they show what an agent exported, including attempts the data layer refused.
In the accompanying blog post: section "What the agent keeps: database-side exports and copies".

## When to use it

After you limit exports with [data-layer Exports and copies](../../data-layer/README.md#exports-and-copies), to prove the limits hold and to see every export that did run. It addresses excessive agency: row-level security and masking end when a result leaves Redshift.

## Who runs it

- The monitoring role with `sys:monitor`, for `export-audit.sql`.
- A CloudTrail administrator, for the trail.
- An Athena user with read access to the trail bucket, for `cloudtrail-s3-writes.sql`.

## Prerequisites

- `sys:monitor` for the monitoring user ([observe Prerequisites](../README.md#prerequisites)).
- A bucket for the trail's logs with the CloudTrail bucket policy (`s3:GetBucketAcl` and `s3:PutObject` for `cloudtrail.amazonaws.com`, with `aws:SourceArn` set to the trail ARN). See [Amazon S3 bucket policy for CloudTrail](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html).
- Permissions to create a trail: `cloudtrail:CreateTrail`, `cloudtrail:PutEventSelectors` and `cloudtrail:StartLogging`.
- An Athena database (`<audit_db>`) and a query result location.
- The bucket that UNLOAD writes to (`<unload-bucket>`).

Placeholders:
- `<trail-name>`, `<trail-bucket>`: the trail and its log bucket.
- `<unload-bucket>`: the export bucket, inside `cloudtrail-s3-data-events-selectors.json` and `cloudtrail-s3-writes.sql`.
- `<audit_db>`: the Athena database.
- `<account-id>`, `<region>`: the account and Region of the trail.
- `<projection-start-yyyy/MM/dd>`: the first day of the trail's data, for example `2026/01/01`.
- `<yyyy/MM/dd>`, `<start-utc>`, `<end-utc>`: the day and time window of query 2 in `cloudtrail-s3-writes.sql`.
- `'IAMR:agent-%'` and the 7-day window in `export-audit.sql`.

## How it works

This group is the EXPORT AUDIT box of the [observe workflow](../../images/observe-workflow.png); it reads system views and CloudTrail.

- `export-audit.sql` query 1 lists UNLOAD by agent users from SYS_UNLOAD_HISTORY, with status, location and row count; query 2 lists CTAS, INSERT and UNLOAD statements from SYS_QUERY_HISTORY, including failed ones.
- The trail records only object writes under the export bucket, as CloudTrail S3 data events. UNLOAD writes are made by the IAM role Redshift assumes for the UNLOAD (session `RedshiftIamRoleSession`, invoked by `redshift.amazonaws.com`), not by the agent's role, so match each write to the agent's statement in `export-audit.sql` by S3 prefix and time.
- Data events are billed per event; the selector logs only object writes on one bucket and no management events. See [AWS CloudTrail pricing](https://aws.amazon.com/cloudtrail/pricing/) and [Logging data events](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/logging-data-events-with-cloudtrail.html).

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`export-audit.sql`](export-audit.sql) | Query 1: UNLOAD by agent users from SYS_UNLOAD_HISTORY. Query 2: CTAS, INSERT and UNLOAD statements by agent users from SYS_QUERY_HISTORY, with failures | Set up step 1 | runs as the monitoring role with `sys:monitor` |
| [`cloudtrail-s3-data-events.sh`](cloudtrail-s3-data-events.sh) | AWS CLI lines that create a single-Region trail, set its event selector, start logging, and show the selector. Quoted below, never run as a script | Set up step 2, Verify | run as a CloudTrail administrator |
| [`cloudtrail-s3-data-events-selectors.json`](cloudtrail-s3-data-events-selectors.json) | One advanced event selector: S3 object writes (`readOnly` false) under `arn:aws:s3:::<unload-bucket>/` | Set up step 2, `put-event-selectors` | none (event selector) |
| [`cloudtrail-s3-writes.sql`](cloudtrail-s3-writes.sql) | Part 1 creates the Athena database and a partition-projected table over the trail's logs; part 2 lists object writes to the export bucket in a time window | Set up step 3 | runs as an Athena user |

## Set up

Run each block from the repository root; each one starts with the `cd` it needs.

### 1. Audit exports in Redshift

Run [`export-audit.sql`](export-audit.sql) as the [monitoring role](../README.md#prerequisites), in database `dev`. Sample output of query 1 (illustrative values):

```text
agent_user         | query_id | start_time            | status    | file_format | unloaded_location             | unloaded_rows | unloaded_files_count | unloaded_files_size | error_message
IAMR:agent-support | <id>     | <yyyy-mm-dd hh:mm:ss> | completed | text        | s3://<unload-bucket>/<prefix> | <n>           | <n>                  | <bytes>             |
```

Sample output of query 2 (illustrative values):

```text
agent_user         | query_id | start_time            | query_type | status | returned_rows | query_text          | error_message
IAMR:agent-support | <id>     | <yyyy-mm-dd hh:mm:ss> | UNLOAD     | failed | 0             | <first 200 chars>   | User ... does not have ASSUMEROLE permission on IAM role "..." for UNLOAD
```

### 2. Record bucket writes with CloudTrail

Replace `<unload-bucket>` in `cloudtrail-s3-data-events-selectors.json` first. Then the `create-trail`, `put-event-selectors` and `start-logging` lines of `cloudtrail-s3-data-events.sh`, quoted as written:

```bash
cd observe/export-audit
aws cloudtrail create-trail --name <trail-name> --s3-bucket-name <trail-bucket> \
  --no-is-multi-region-trail --no-include-global-service-events --enable-log-file-validation \
  --region <region>
aws cloudtrail put-event-selectors --trail-name <trail-name> \
  --advanced-event-selectors file://cloudtrail-s3-data-events-selectors.json --region <region>
aws cloudtrail start-logging --name <trail-name> --region <region>
```

What this does:
- Creates the single-Region trail `<trail-name>`, which writes to `<trail-bucket>`, with `--enable-log-file-validation`.
- Sets one advanced event selector, so the trail records only object writes under the export bucket and no management events.
- Starts logging.

### 3. Create the CloudTrail table in Athena

Replace `<projection-start-yyyy/MM/dd>` in [`cloudtrail-s3-writes.sql`](cloudtrail-s3-writes.sql) with the first day of your trail's data, for example `2026/01/01`. Keep `,NOW` after it. Partition projection then covers every day from that date to today. Also replace `<trail-bucket>`, `<account-id>`, `<region>` and `<audit_db>`. Run part 1 in Athena once. See [Use partition projection with Amazon Athena](https://docs.aws.amazon.com/athena/latest/ug/partition-projection.html).

### 4. Query the bucket writes

Replace `<yyyy/MM/dd>`, `<unload-bucket>`, `<start-utc>` and `<end-utc>` in part 2 and run it in Athena. Sample output (illustrative values):

```text
eventtime              | eventname               | caller_arn                                                               | role_arn                                  | invoked_by             | sourceipaddress | useragent      | object_key      | errorcode
<yyyy-mm-ddThh:mm:ssZ> | CompleteMultipartUpload | arn:aws:sts::111122223333:assumed-role/etl-unload/RedshiftIamRoleSession | arn:aws:iam::111122223333:role/etl-unload | redshift.amazonaws.com | <source>        | <user-agent>   | <prefix>/<file> |
```

## Verify

Check the trail's selector with the `get-event-selectors` line of `cloudtrail-s3-data-events.sh`, quoted as written:

```bash
cd observe/export-audit
aws cloudtrail get-event-selectors --trail-name <trail-name> --region <region>
```

| Check | Run as | Expected result |
| --- | --- | --- |
| `get-event-selectors` | CloudTrail administrator | one advanced event selector, "S3 object writes on the export bucket" |
| `export-audit.sql` query 1, after an UNLOAD by an agent user | monitoring role | the UNLOAD with status `completed`, its S3 location and row count |
| `export-audit.sql`, after an UNLOAD the data layer refused | monitoring role | `aborted` in query 1, and `failed` with the error in query 2 |
| `cloudtrail-s3-writes.sql` part 1 | Athena user | the `CREATE EXTERNAL TABLE` statement succeeds |
| `cloudtrail-s3-writes.sql` part 2, about 15 minutes after the UNLOAD | Athena user | `CreateMultipartUpload`, `UploadPart` and `CompleteMultipartUpload` rows for the unload prefix, under the role Redshift assumed |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `aws cloudtrail lookup-events` shows no S3 writes | Data events don't appear in event history | Query them with `cloudtrail-s3-writes.sql` |
| Part 2 returns no rows | The writes are less than about 15 minutes old, `<projection-start-yyyy/MM/dd>` is after the events, or the account or Region in `LOCATION` doesn't match the trail. Writes made in the first minutes after `start-logging` can also be missing, because the new event selector isn't applied yet | Wait, then check the projection start date and the `LOCATION` path. For a test, run the UNLOAD again a few minutes after the trail starts logging |
| The bucket writes show the UNLOAD's IAM role, not the agent's role | Expected: Redshift writes with the IAM role in the UNLOAD | Match the writes to the agent's statement in `export-audit.sql` by S3 prefix and time |
| `export-audit.sql` lists only the monitoring user's own rows | The monitoring user doesn't hold `sys:monitor` | Grant it ([observe Prerequisites](../README.md#prerequisites)) |

## Clean up

Stop and delete the trail (it's a single-Region trail, so pass its Region):

```bash
cd observe/export-audit
aws cloudtrail stop-logging --name <trail-name> --region <region>
aws cloudtrail delete-trail --name <trail-name> --region <region>
```

Then empty and delete the trail bucket if you created it for this. In Athena:

```sql
DROP TABLE <audit_db>.cloudtrail_s3_writes;
DROP DATABASE <audit_db>;  -- only if you created it for this
```

`export-audit.sql` only reads system views; there's nothing to undo.

## Used by

- [data-layer Exports and copies](../../data-layer/README.md#exports-and-copies): this group audits the limits it sets.
- All five access paths, for exports by their agent users.
