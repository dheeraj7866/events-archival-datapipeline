+# Vendor Archive Grafana

This folder contains Grafana dashboards for the vendor archive pipeline. The dashboards are ClickHouse-first, so they work with rows written by `vendor-archiver` from SQS into `vendor_archive.vendor_api_events`.

## Dashboards

- `vendor-business-funnel.json`: business metrics, lifecycle funnel, impacted users, impacted loan applications, vendor reliability.
- `vendor-failure-rate.json`: failure rate, failed calls, timeout/network error rate, failure breakdown.
- `vendor-latency.json`: p50/p95/p99 latency, slow endpoints, timeout trends.
- `vendor-archive-ops-compliance.json`: ingest lag, insert rate, duplicate deliveries, S3 key coverage, payload truncation, redaction watchlist, data completeness.

`vendor-spend.json` was intentionally removed for now because `cost_paise` is not persisted by the current ClickHouse schema/Lambda mapping.

## Metrics Covered

Business:
- total vendor calls
- success/failure rate
- impacted users
- impacted loan applications
- lifecycle-stage health
- vendor reliability ranking
- top failing endpoints

DevOps / pipeline:
- archive insert rate
- p95 ingest lag from `created_at` to `ingested_at`
- duplicate `request_id` deliveries
- slowest vendor endpoints
- timeout and network-error trends

Compliance / data quality:
- rows missing S3 request/response keys
- truncated payload count
- possible unredacted PAN/mobile pattern watchlist in hot ClickHouse payloads
- missing user, LAN, request hash, PAN mask, mobile hash, Aadhaar hash

## Option A: Run Grafana Locally With Docker

Use this when you want the fastest setup on your laptop or dev box.

1. Start an SSM port-forward to the ClickHouse EC2 instance.

```bash
cd vendor-archive-infra/terraform/environments/staging
terraform output clickhouse_private_ip
aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:Name,Values=vendor-archive-staging-clickhouse" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text
aws ssm start-session \
  --region ap-south-1 \
  --target i-xxxxxxxxxxxxxxxxx \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8123"],"localPortNumber":["8123"]}'
```

2. Set or reset the read-only Grafana password on the ClickHouse box if needed.

```bash
aws ssm start-session --region ap-south-1 --target i-xxxxxxxxxxxxxxxxx
clickhouse-client --query "ALTER USER grafana_reader IDENTIFIED BY 'change-this-password'"
```

3. Start Grafana.

On Linux, use host networking so the Grafana container can reach the SSM tunnel on
`127.0.0.1:8123`:

```bash
cd vendor-archive-infra/grafana
CLICKHOUSE_HOST=127.0.0.1 \
CLICKHOUSE_PORT=8123 \
CLICKHOUSE_USER=grafana_reader \
CLICKHOUSE_PASSWORD='change-this-password' \
docker compose -f docker-compose.yml -f docker-compose.linux-host.yml up -d
```

On Docker Desktop for macOS/Windows, use `host.docker.internal`:

```bash
cd vendor-archive-infra/grafana
CLICKHOUSE_HOST=host.docker.internal \
CLICKHOUSE_PORT=8123 \
CLICKHOUSE_USER=grafana_reader \
CLICKHOUSE_PASSWORD='change-this-password' \
docker compose up -d
```

If you previously started Grafana with the wrong host, restart it after changing
the environment:

```bash
docker compose down
CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_PORT=8123 CLICKHOUSE_USER=grafana_reader CLICKHOUSE_PASSWORD='change-this-password' docker compose -f docker-compose.yml -f docker-compose.linux-host.yml up -d
```

4. Open Grafana.

- URL: `http://localhost:3000`
- User: `admin`
- Password: `admin` unless you set `GRAFANA_ADMIN_PASSWORD`
- Folder: `Vendor Archive`

## Option B: Existing Grafana Server

1. Install the ClickHouse datasource plugin:

```bash
grafana-cli plugins install grafana-clickhouse-datasource
sudo systemctl restart grafana-server
```

2. Add a ClickHouse datasource:

- Type: `ClickHouse`
- URL/host: ClickHouse private IP or DNS reachable from Grafana
- HTTP port: `8123`
- Database: `vendor_archive`
- User: `grafana_reader`
- Password: your `grafana_reader` password

3. Import dashboard JSON files from `vendor-archive-infra/grafana/dashboards`.

Choose the ClickHouse datasource during import.

## Generate Data For Dashboards

Run the continuous test sender:

```bash
ENV=staging RATE_PER_MIN=120 BATCH_SIZE=10 ./vendor-archive-infra/scripts/send-random-stream.sh
```

For a bounded run:

```bash
ENV=staging MAX_MESSAGES=1000 RATE_PER_MIN=180 BATCH_SIZE=10 ./vendor-archive-infra/scripts/send-random-stream.sh
```

Then wait around 15-60 seconds for SQS and Lambda to write rows into ClickHouse.

## Quick ClickHouse Checks

Use these before blaming Grafana. Tiny sanity checks save a lot of dashboard staring.

```sql
SELECT count() FROM vendor_archive.vendor_api_events;

SELECT
  vendor_id,
  status,
  count() AS calls
FROM vendor_archive.vendor_api_events
WHERE created_at >= now() - INTERVAL 1 HOUR
GROUP BY vendor_id, status
ORDER BY calls DESC;

SELECT
  max(created_at) AS latest_event,
  max(ingested_at) AS latest_ingest,
  quantile(0.95)(dateDiff('second', created_at, ingested_at)) AS p95_ingest_lag_seconds
FROM vendor_archive.vendor_api_events;
```

## Troubleshooting

- Empty dashboards: confirm the random stream is sending to the same `ENV` that Lambda writes as `environment`.
- Datasource test fails: confirm Grafana can reach ClickHouse HTTP port `8123`.
- Permission error: use `grafana_reader`, not `archiver` or `default`.
- Import asks for datasource: select your ClickHouse datasource.
- Spend panels missing: expected for now; current schema does not persist `cost_paise`.
