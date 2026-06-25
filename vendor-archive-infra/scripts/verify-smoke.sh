#!/usr/bin/env bash
# verify-smoke.sh — trace a synthetic vendor event through SQS → Lambda → S3,
# and print a verdict on where it ended up. Read-only; safe to re-run.
#
# Usage:
#   ./verify-smoke.sh [request_id] [vendor_id]
# Env overrides:
#   ENV=staging (ap-south-2) | prod (ap-south-1)   — region+bucket auto-derived
#
# Defaults match the Gate-4 smoke message in the readiness checklist.
set -uo pipefail

ENV="${ENV:-staging}"
case "$ENV" in
  staging) REGION="${REGION:-ap-south-1}"; SUFFIX="aps2" ;;
  prod)    REGION="${REGION:-ap-south-1}"; SUFFIX="aps1" ;;
  *) echo "FATAL: unknown ENV '$ENV' (use staging|prod)"; exit 1 ;;
esac
PREFIX="vendor-archive-${ENV}"
FN="${PREFIX}-vendor-archiver"
BUCKET="${PREFIX}-${SUFFIX}"
REQUEST_ID="${1:-00000000-0000-0000-0000-000000000001}"
VENDOR_ID="${2:-smoke}"

bold(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
val(){ [ -z "${1:-}" ] || [ "$1" = "None" ] && echo 0 || echo "$1"; }

bold "▶ verify-smoke  region=$REGION env=$ENV  request_id=$REQUEST_ID  vendor_id=$VENDOR_ID"

QURL=$(aws sqs get-queue-url --region "$REGION" --queue-name "${PREFIX}-vendor-events-q"   --query QueueUrl --output text 2>/dev/null || echo "")
DLQ=$(aws sqs  get-queue-url --region "$REGION" --queue-name "${PREFIX}-vendor-events-dlq" --query QueueUrl --output text 2>/dev/null || echo "")
[ -z "$QURL" ] && { echo "FATAL: main queue ${PREFIX}-vendor-events-q not found in $REGION"; exit 1; }

bold "1) Queue depths"
MAIN_VIS=$(aws sqs get-queue-attributes --region "$REGION" --queue-url "$QURL" --attribute-names ApproximateNumberOfMessages         --query 'Attributes.ApproximateNumberOfMessages'         --output text 2>/dev/null)
MAIN_INF=$(aws sqs get-queue-attributes --region "$REGION" --queue-url "$QURL" --attribute-names ApproximateNumberOfMessagesNotVisible --query 'Attributes.ApproximateNumberOfMessagesNotVisible' --output text 2>/dev/null)
DLQ_N=$(aws sqs   get-queue-attributes --region "$REGION" --queue-url "$DLQ"  --attribute-names ApproximateNumberOfMessages          --query 'Attributes.ApproximateNumberOfMessages'         --output text 2>/dev/null)
MAIN_VIS=$(val "$MAIN_VIS"); MAIN_INF=$(val "$MAIN_INF"); DLQ_N=$(val "$DLQ_N")
echo "   main: waiting=$MAIN_VIS  in-flight=$MAIN_INF   |   dlq=$DLQ_N"

bold "2) Event source mapping (SQS → Lambda trigger)"
UUID=$(aws lambda list-event-source-mappings --region "$REGION" --function-name "$FN" --query "EventSourceMappings[0].UUID" --output text 2>/dev/null)
if [ -n "$UUID" ] && [ "$UUID" != "None" ]; then
  aws lambda get-event-source-mapping --region "$REGION" --uuid "$UUID" \
    --query "{State:State,Reason:StateTransitionReason,LastResult:LastProcessingResult,Batch:BatchSize}" --output table
else
  echo "   ⚠ no event source mapping found — the Lambda is NOT wired to SQS"
fi

bold "3) Reserved concurrency  (0 = every invoke is throttled → silent DLQ)"
RC=$(aws lambda get-function-concurrency --region "$REGION" --function-name "$FN" --query "ReservedConcurrentExecutions" --output text 2>/dev/null)
[ -z "$RC" ] || [ "$RC" = "None" ] && echo "   unreserved (uses account pool) — OK" || echo "   ReservedConcurrentExecutions = $RC $( [ "$RC" = "0" ] && echo '  ❌ THIS BLOCKS ALL INVOCATIONS')"

bold "4) Lambda invoke metrics (last 1h)"
START=$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '1 hour ago' +%FT%TZ)
END=$(date -u +%FT%TZ)
INV=0
for M in Invocations Errors Throttles; do
  V=$(aws cloudwatch get-metric-statistics --region "$REGION" --namespace AWS/Lambda --metric-name "$M" \
        --dimensions Name=FunctionName,Value="$FN" --start-time "$START" --end-time "$END" \
        --period 3600 --statistics Sum --query "Datapoints[0].Sum" --output text 2>/dev/null)
  V=$(val "$V"); [ "$M" = "Invocations" ] && INV="$V"
  printf "   %-12s %s\n" "$M:" "$V"
done

bold "5) Recent logs (last 1h)"
aws logs tail "/aws/lambda/$FN" --region "$REGION" --since 1h --format short 2>&1 | tail -15 \
  || echo "   (no log group / no events — function likely never invoked)"

bold "6) S3 objects containing this request_id"
echo "   bucket: $BUCKET"   # ${PREFIX}-${SUFFIX}, derived from ENV
HITS=$(aws s3 ls "s3://$BUCKET/" --recursive --region "$REGION" 2>/dev/null | grep "$REQUEST_ID" || true)
[ -n "$HITS" ] && echo "$HITS" | sed 's/^/   /' || echo "   (no S3 object yet for $REQUEST_ID)"

bold "7) ClickHouse — run on the CH box via SSM (private, not reachable from here)"
cat <<EOF
   # This ClickHouse instance is private. Do NOT run this locally unless you have
   # a tunnel or SSM session into the CH host.
   clickhouse-client --query "SELECT request_id, vendor_id, status, request_payload, ingested_at
     FROM vendor_archive.vendor_api_events WHERE request_id='$REQUEST_ID' FORMAT Vertical"
   (expect request_payload masked → ABC****34F, never the raw PAN)
EOF

bold "VERDICT"
if [ "$DLQ_N" -gt 0 ]; then
  if [ "$INV" = "0" ]; then
    echo "   ❌ DEAD-LETTERED with ZERO invocations → the poller could not invoke the function."
    echo "      Prime suspects: reserved concurrency = 0 (step 3), VPC ENI/subnet, or role missing SQS perms (step 2 reason)."
  else
    echo "   ❌ DEAD-LETTERED after the function ran and failed → read the error in step 5 (likely CH auth/connectivity)."
  fi
  echo "      Inspect the dead message:"
  echo "      aws sqs receive-message --region $REGION --queue-url $DLQ --max-number-of-messages 1 \\"
  echo "        --visibility-timeout 5 --attribute-names ApproximateReceiveCount \\"
  echo "        --query 'Messages[].{Received:Attributes.ApproximateReceiveCount,Body:Body}' --output json"
elif [ "$MAIN_INF" -gt 0 ]; then
  echo "   ⏳ IN-FLIGHT — a Lambda invocation is holding it. Re-run in ~30s."
elif [ "$MAIN_VIS" -gt 0 ]; then
  echo "   ⏳ WAITING in the queue, not consumed. Check the mapping State in step 2 (want Enabled)."
else
  echo "   ✅ queue empty, DLQ empty → likely PROCESSED. Confirm with the S3 hit (step 6) + ClickHouse row (step 7)."
fi
