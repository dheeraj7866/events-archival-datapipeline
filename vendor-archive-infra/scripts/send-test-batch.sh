#!/usr/bin/env bash
# send-test-batch.sh — push a varied set of synthetic events to exercise the pipeline.
# Updated for the hardened wire: schema_version (REQUIRED = 1, else the Lambda skips),
# user_id (drives the S3 folder), and loan_application_number (optional).
# Covers: multiple vendors, all 4 statuses, PII variety (redacted in CH / raw in S3),
# a DUPLICATE request_id (ReplacingMergeTree dedup), and several user_id=dheeraj events.
#
# Usage: ./send-test-batch.sh                 # staging (ap-south-1)
#        ENV=prod ./send-test-batch.sh         # prod (ap-south-1)
#        BULK=50 ENV=prod ./send-test-batch.sh # also fire BULK random extra messages
set -uo pipefail
ENV="${ENV:-staging}"
case "$ENV" in
  staging) REGION="${REGION:-ap-south-1}" ;;
  prod)    REGION="${REGION:-ap-south-1}" ;;
  *) echo "FATAL: unknown ENV '$ENV' (use staging|prod)"; exit 1 ;;
esac
QURL=$(aws sqs get-queue-url --region "$REGION" --queue-name "vendor-archive-${ENV}-vendor-events-q" --query QueueUrl --output text)
echo "▶ ENV=$ENV REGION=$REGION"
NOW=$(date -u +%FT%TZ)
uuid(){ uuidgen | tr 'A-Z' 'a-z'; }

# send <rid> <vendor> <endpoint> <stage> <status> <http> <lat> <cost> <reqp> <resp> <user_id> <lan>
send() {
  local body
  body=$(python3 - "$@" "$NOW" <<'PY'
import json, sys
rid,vendor,ep,stage,status,http,lat,cost,reqp,resp,user_id,lan,now = sys.argv[1:14]
msg = {
  "schema_version": 1,                       # REQUIRED — Lambda skips events where != 1
  "request_id": rid, "correlation_id": "batch-"+rid[:8], "created_at": now,
  "service": "identity-api", "environment": "staging",
  "vendor_id": vendor, "endpoint": ep,
  "loan_lifecycle_stage": stage,             # must be a valid Enum8 member
  "application_id": "app-"+rid[:6],
  "user_id": user_id,                        # drives the S3 .../{user_id}/... folder
  "status": status,
  "http_status": int(http), "latency_ms": int(lat), "cost_paise": int(cost),
  "request_payload": reqp,                   # library sends payloads as JSON *strings*
  "response_payload": resp,
  "payload_truncated": False, "request_hash": "hash-"+rid[:12],
}
if lan:
    msg["loan_application_number"] = lan
print(json.dumps(msg))
PY
)
  local id; id=$(aws sqs send-message --region "$REGION" --queue-url "$QURL" --message-body "$body" --query MessageId --output text)
  echo "  sent $2/$5  user_id=${11}  rid=$1  msg=$id"
}

echo "▶ curated set → $QURL"
DUP=$(uuid)   # reused twice to test dedup

#     rid          vendor    endpoint          stage             status         http  lat   cost  request_payload                                                            response_payload                          user_id        loan_application_number
send "$(uuid)" karza    /kyc/verify     KYC              SUCCESS       200 142   150 '{"pan":"ABCDE1234F","mobile":"9876543210","email":"rakesh@gmail.com"}' '{"ok":true,"aadhaar":"1234 5678 9012"}' dheeraj       LAN-DHEERAJ-001
send "$(uuid)" digitap  /bank/statement BANK_BRE         SUCCESS       200 880   300 '{"accountNumber":"1234567890","ifsc":"HDFC0001234"}'                  '{"txnCount":42}'                        dheeraj       ''
send "$(uuid)" signzy   /pan/validate   PAN_AADHAAR_SEED FAILURE       422 95     50 '{"pan":"ZZZZZ9999Z"}'                                                 '{"error":"invalid pan"}'                user-9001     ''
send "$(uuid)" easebuzz /payout         DISBURSED        TIMEOUT         0 30000 200 '{"beneficiaryAccount":"9988776655","amount":500000,"phone":"9123456789"}' 'null'                                dheeraj       LAN-DHEERAJ-002
send "$(uuid)" crif     /bureau/pull    BUREAU_BRE       NETWORK_ERROR   0 5000    0 '{"pan":"PQRST5678U"}'                                                 'null'                                   user-7777     LAN-7777
send "$(uuid)" nsdl     /aadhaar/seed   PAN_AADHAAR_SEED SUCCESS       200 210   120 '{"aadhaar":"999988887777","pan":"LMNOP1234Q"}'                       '{"seeded":true}'                        dheeraj       ''
# duplicate request_id (same payload, sent twice) → ReplacingMergeTree should keep one
send "$DUP"    karza    /kyc/verify     KYC              SUCCESS       200 130   150 '{"pan":"AAAAA1111A"}' '{"ok":true}'                                                                            dheeraj-dup   ''
send "$DUP"    karza    /kyc/verify     KYC              SUCCESS       200 131   150 '{"pan":"AAAAA1111A"}' '{"ok":true}'                                                                            dheeraj-dup   ''

if [ "${BULK:-0}" -gt 0 ]; then
  echo "▶ BULK: $BULK random messages"
  V=(karza digitap signzy easebuzz crif nsdl); S=(SUCCESS FAILURE TIMEOUT NETWORK_ERROR)
  for i in $(seq 1 "$BULK"); do
    UID_I=$([ $((i % 2)) -eq 0 ] && echo "dheeraj" || echo "user-$i")
    send "$(uuid)" "${V[$((RANDOM%6))]}" /auto/$i UNDERWRITING "${S[$((RANDOM%4))]}" 200 $((RANDOM%2000)) $((RANDOM%500)) "{\"pan\":\"ABCDE${i}234F\",\"mobile\":\"98765${i}3210\"}" '{"ok":true}' "$UID_I" '' >/dev/null
  done
  echo "  done"
fi

echo "✅ enqueued. Verify in ~15-30s (see commands printed by the script note)."
echo "   DUP request_id (dedup check): $DUP"
echo "   user_id=dheeraj events: karza, digitap, easebuzz, nsdl (4)"
