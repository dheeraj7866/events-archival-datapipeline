# EMERGENCY / Ops Runbook — vendor-archive

Fast reference for "where is my data / why isn't it flowing / how do I find an event."
Region `ap-south-2`. Resource prefix `vendor-archive-staging-*` (swap `staging`→`prod`).
For deeper infra/credentials see [README.md](README.md); for the contract see [../CONVENTIONS.md](../CONVENTIONS.md).

> **Golden rule:** ClickHouse holds the **redacted, queryable** copy (90-day TTL). **S3 holds the RAW,
> immutable** copy (Object Lock COMPLIANCE, forever). Raw PAN/Aadhaar/mobile live **only in S3**, never in CH.

---

## 0. 30-second health triage

```bash
# one-shot pipeline state (queue → metrics → logs → S3)
cd vendor-archive-infra && ./scripts/verify-smoke.sh

# or the raw counters
REGION=ap-south-2
QURL=$(aws sqs get-queue-url --region $REGION --queue-name vendor-archive-staging-vendor-events-q --query QueueUrl --output text)
aws sqs get-queue-attributes --region $REGION --queue-url "$QURL" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
aws sqs get-queue-attributes --region $REGION --queue-url "${QURL%-q}-dlq" --attribute-names ApproximateNumberOfMessages
```
- `dlq > 0` → events are failing — see §3.
- main `waiting` climbing → Lambda not keeping up / can't invoke — see §2.
- all 0 → healthy.

---

## 1. Grep the Lambda logs (CloudWatch)

Log group: `/aws/lambda/vendor-archive-staging-vendor-archiver`

```bash
REGION=ap-south-2; LG=/aws/lambda/vendor-archive-staging-vendor-archiver

# live tail
aws logs tail $LG --region $REGION --since 15m --follow --format short

# only errors in the last hour
aws logs filter-log-events --region $REGION --log-group-name $LG \
  --filter-pattern "error" --start-time $(( $(date +%s) - 3600 ))000 \
  --query "events[].message" --output text

# batch outcomes (succeeded/failed counts)
aws logs filter-log-events --region $REGION --log-group-name $LG \
  --filter-pattern '"Batch processed"' --start-time $(( $(date +%s) - 3600 ))000 \
  --query "events[].message" --output text
```
The Lambda logs **never** include payloads — only `requestId`, `vendorId`, `status`, counts. To trace a specific
event end-to-end, use its `correlation_id` / `request_id` in ClickHouse (§2) and S3 (§4).

Lambda health metrics (invoked? erroring? throttling?):
```bash
for M in Invocations Errors Throttles Duration; do printf "%s: " $M; \
  aws cloudwatch get-metric-statistics --region $REGION --namespace AWS/Lambda --metric-name $M \
  --dimensions Name=FunctionName,Value=vendor-archive-staging-vendor-archiver \
  --start-time $(date -u -v-1H +%FT%TZ) --end-time $(date -u +%FT%TZ) --period 3600 \
  --statistics Sum Maximum --query "Datapoints[0]" --output text; done
```

---

## 2. Query ClickHouse (the queryable archive)

Connect via SSM (CH is private; no public IP):
```bash
aws ssm start-session --target <i-...> --region ap-south-2
clickhouse-client                       # default user, full access (debug)
```
Table: `vendor_archive.vendor_api_events`. **Run SQL inside `clickhouse-client`, never in bash.**

### Find an event
```sql
-- by request_id
SELECT * FROM vendor_archive.vendor_api_events WHERE request_id = '<uuid>' FORMAT Vertical;

-- by correlation_id (trace one user request across multiple vendor calls)
SELECT created_at, service, vendor_id, endpoint, status, http_status, latency_ms
FROM vendor_archive.vendor_api_events WHERE correlation_id = '<corr-id>' ORDER BY created_at;

-- by application / user (customer support lookups)
SELECT created_at, vendor_id, endpoint, status, error_code, s3_request_key
FROM vendor_archive.vendor_api_events WHERE application_id = '<app>' ORDER BY created_at;
SELECT * FROM vendor_archive.vendor_api_events WHERE user_id = '<user>' ORDER BY created_at DESC LIMIT 50 FORMAT Vertical;

-- by masked PII (you only ever have the derivative, never the raw value)
SELECT * FROM vendor_archive.vendor_api_events WHERE pan_masked = 'ABC****34F' FORMAT Vertical;
SELECT * FROM vendor_archive.vendor_api_events WHERE mobile_hash = '<hmac-hex>' FORMAT Vertical;
```

### Triage / incident queries
```sql
-- failure rate by vendor, last hour
SELECT vendor_id, status, count() AS n FROM vendor_archive.vendor_api_events
WHERE created_at >= now() - INTERVAL 1 HOUR GROUP BY vendor_id, status ORDER BY vendor_id, n DESC;

-- recent failures with the error text
SELECT created_at, vendor_id, endpoint, status, http_status, error_code, error_message
FROM vendor_archive.vendor_api_events
WHERE status != 'SUCCESS' AND created_at >= now() - INTERVAL 1 HOUR ORDER BY created_at DESC LIMIT 100;

-- latency hot spots
SELECT vendor_id, endpoint, count() AS calls,
       quantile(0.5)(latency_ms) p50, quantile(0.95)(latency_ms) p95, max(latency_ms) max_ms
FROM vendor_archive.vendor_api_events WHERE created_at >= now() - INTERVAL 1 HOUR
GROUP BY vendor_id, endpoint ORDER BY p95 DESC;

-- spend today (paise → INR)
SELECT vendor_id, sum(cost_paise)/100.0 AS inr FROM vendor_archive.vendor_api_events
WHERE toDate(created_at) = today() GROUP BY vendor_id ORDER BY inr DESC;

-- PII LEAK AUDIT — must be 0 (raw values should never be in CH)
SELECT count() FROM vendor_archive.vendor_api_events
WHERE match(request_payload, '[A-Z]{5}[0-9]{4}[A-Z]') OR match(response_payload, '\\b\\d{12}\\b');

-- dedup-correct counts (ReplacingMergeTree collapses retries on request_id)
SELECT count() FROM vendor_archive.vendor_api_events FINAL;
```

### If a query says `Not enough privileges` (the archiver/MV path)
```sql
SHOW GRANTS FOR archiver;   -- must show: INSERT on the table, SELECT(6 cols) on the table, INSERT on vendor_failure_counts_1m
```

---

## 3. DLQ — inspect & redrive

```bash
REGION=ap-south-2
DLQ=$(aws sqs get-queue-url --region $REGION --queue-name vendor-archive-staging-vendor-events-dlq --query QueueUrl --output text)

# how many, and read one (with its receive count) to see WHY it failed
aws sqs get-queue-attributes --region $REGION --queue-url "$DLQ" --attribute-names ApproximateNumberOfMessages
aws sqs receive-message --region $REGION --queue-url "$DLQ" --max-number-of-messages 1 \
  --visibility-timeout 5 --attribute-names ApproximateReceiveCount \
  --query "Messages[].{Received:Attributes.ApproximateReceiveCount,Body:Body}" --output json
# (the real reason is in the Lambda error log — §1)

# after fixing the root cause, redrive everything back to the main queue
DLQ_ARN=$(aws sqs get-queue-attributes --region $REGION --queue-url "$DLQ" --attribute-names QueueArn --query Attributes.QueueArn --output text)
aws sqs start-message-move-task --region $REGION --source-arn "$DLQ_ARN"
```

**Common DLQ causes (seen in bring-up — see [../INTEGRATION.md](../INTEGRATION.md) §6):** missing `kms:Decrypt`,
empty CH secret, wrong CH port (must be 8123 HTTP), CH not listening on 0.0.0.0, missing SG ingress on 8123,
`archiver` missing MV grants. Note: S3 objects are written **before** the CH insert, so a CH-side failure leaves
an S3 object present but no CH row — that asymmetry is a useful signal.

---

## 4. S3 — the raw, immutable archive

Bucket: `vendor-archive-staging-aps2`. Key layout (deterministic):
```
YYYY/MM/DD/{vendor_id}/{endpoint}/{request_id}/request.json.gz
YYYY/MM/DD/{vendor_id}/{endpoint}/{request_id}/response.json.gz
```
Body = gzip of `{ "meta": {...}, "payload": "<raw vendor payload>" }`. Encrypted SSE-KMS; **Object Lock COMPLIANCE +
Legal Hold ON** (immutable — even root cannot delete; see §6).

### Retrieve the raw payload for an event
```bash
REGION=ap-south-2; BUCKET=vendor-archive-staging-aps2
# 1) get the exact key from ClickHouse (no guessing the path):
#    clickhouse-client --query "SELECT s3_request_key, s3_response_key FROM vendor_archive.vendor_api_events WHERE request_id='<uuid>'"
KEY="2026/05/30/karza/kyc_verify/<uuid>/request.json.gz"

# 2) download + decompress (needs s3:GetObject + kms:Decrypt — audit-reader role, MFA)
aws s3 cp "s3://$BUCKET/$KEY" - --region $REGION | gunzip | python3 -m json.tool

# list everything for one request
aws s3 ls "s3://$BUCKET/2026/05/30/karza/kyc_verify/<uuid>/" --recursive --region $REGION
```
Reads are CloudTrail-logged; a spike (>20 GetObject/5min) fires an alarm. Use the `audit-reader` role (MFA) for
reads — the Lambda's `archiver-writer` role can write but **cannot** read S3 back.

### Recovery: re-ingest S3 → ClickHouse
If ClickHouse data is lost (within or beyond the 90-day TTL), S3 is the source of truth. There is **no replay
Lambda yet** (HARDENING P3-3) — interim: list the S3 keys for the window, fetch + gunzip each, and `INSERT` the
`payload` (re-redacted) into `vendor_api_events`. Athena-over-S3 for ad-hoc audit is Phase 2 (not built).

---

## 5. ClickHouse box / Lambda recovery (pointers)

```bash
# CH service
sudo systemctl status clickhouse-server ; sudo tail -100 /var/log/clickhouse-server/clickhouse-server.err.log
sudo systemctl restart clickhouse-server
ss -tlnp | grep -E ':8123|:9000'                 # must listen on 0.0.0.0, not 127.0.0.1
curl -s http://localhost:8123/ping               # expect: Ok.

# Force Lambda to re-read the CH secret (after rotation)
aws lambda update-function-configuration --region ap-south-2 \
  --function-name vendor-archive-staging-vendor-archiver --description "cold start $(date +%s)"
```
Rotate the CH archiver password: set it in CH (`ALTER USER archiver IDENTIFIED BY '<new>'`) **and** Secrets
Manager (`put-secret-value` on `vendor-archive-staging/clickhouse/archiver-password`) — they must match. Runbook in
[README.md](README.md) §7.

---

## 6. Compliance / Legal Hold (break-glass)

S3 objects are immutable (Object Lock COMPLIANCE, 100-yr retention, Legal Hold ON). Removing a Legal Hold is a
**dual-control, MFA** action restricted to the `compliance-officer` role — and it fires a CRITICAL alarm
immediately. Only for court order / legal process. Procedure in [README.md](README.md) §7. Do **not** attempt
deletes through any other role; they will be denied by bucket policy + SCP.

---

## Quick links
- Pipeline status: [../STATUS.md](../STATUS.md) · Contract: [../CONVENTIONS.md](../CONVENTIONS.md)
- What broke during bring-up + where each fix lives: [../INTEGRATION.md](../INTEGRATION.md) §6
- Smoke/verify tooling: `scripts/verify-smoke.sh`, `scripts/send-test-batch.sh`
