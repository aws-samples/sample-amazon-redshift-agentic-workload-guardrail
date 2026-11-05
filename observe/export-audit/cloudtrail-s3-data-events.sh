# Purpose: record every object write to the bucket that UNLOAD can reach, as CloudTrail S3 data events,
#   so bucket writes can be audited next to SYS_UNLOAD_HISTORY (export-audit.sql).
# Post section: "What the agent keeps: database-side exports and copies" (CloudTrail S3 data events for bucket writes).
# Prerequisites:
#   - A bucket for the trail's logs with the CloudTrail bucket policy (s3:GetBucketAcl and s3:PutObject for
#     cloudtrail.amazonaws.com, conditioned on aws:SourceArn = the trail ARN); see "Amazon S3 bucket policy for
#     CloudTrail" in the CloudTrail User Guide.
#   - Permissions to create a trail (cloudtrail:CreateTrail, PutEventSelectors, StartLogging).
# Placeholders: <trail-name>, <trail-bucket>, <region>; <unload-bucket> inside cloudtrail-s3-data-events-selectors.json.
# Cost: data events are billed per event (see CloudTrail pricing). The selector logs only object writes on one
#   bucket and no management events, so this trail doesn't bill a second copy of management events.
# Data events don't appear in `aws cloudtrail lookup-events` (event history); query them with cloudtrail-s3-writes.sql.

aws cloudtrail create-trail --name <trail-name> --s3-bucket-name <trail-bucket> \
  --no-is-multi-region-trail --no-include-global-service-events --enable-log-file-validation \
  --region <region>
aws cloudtrail put-event-selectors --trail-name <trail-name> \
  --advanced-event-selectors file://cloudtrail-s3-data-events-selectors.json --region <region>
aws cloudtrail start-logging --name <trail-name> --region <region>
aws cloudtrail get-event-selectors --trail-name <trail-name> --region <region>
