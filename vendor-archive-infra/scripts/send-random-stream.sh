#!/usr/bin/env bash
# send-random-stream.sh - continuously enqueue random vendor archive events.
#
# Intended for feeding Grafana dashboards with varied status, latency, vendor,
# endpoint, service, lifecycle, user, and spend dimensions.
#
# Usage:
#   ./send-random-stream.sh
#   ENV=prod RATE_PER_MIN=120 ./send-random-stream.sh
#   BATCH_SIZE=10 INTERVAL_SECONDS=2 MAX_MESSAGES=500 ./send-random-stream.sh
#   DRY_RUN=1 BATCH_SIZE=3 ./send-random-stream.sh
#
# Env knobs:
#   ENV               staging|prod. Default: staging
#   REGION            AWS region. Default: ap-south-1
#   QURL              Optional explicit SQS queue URL
#   RATE_PER_MIN      Messages per minute. Default: 60
#   BATCH_SIZE        Messages sent per SQS batch, 1..10. Default: 5
#   INTERVAL_SECONDS  Override sleep between batches. Default derived from rate
#   MAX_MESSAGES      Stop after N messages. Default: unlimited
#   DRY_RUN           Print generated batch and exit without sending when set to 1
set -euo pipefail

ENV="${ENV:-staging}"
REGION="${REGION:-ap-south-1}"
RATE_PER_MIN="${RATE_PER_MIN:-60}"
BATCH_SIZE="${BATCH_SIZE:-5}"
MAX_MESSAGES="${MAX_MESSAGES:-0}"
DRY_RUN="${DRY_RUN:-0}"

case "$ENV" in
  staging|prod) ;;
  *) echo "FATAL: unknown ENV '$ENV' (use staging|prod)" >&2; exit 1 ;;
esac

if ! [[ "$RATE_PER_MIN" =~ ^[0-9]+$ ]] || [ "$RATE_PER_MIN" -le 0 ]; then
  echo "FATAL: RATE_PER_MIN must be a positive integer" >&2
  exit 1
fi

if ! [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || [ "$BATCH_SIZE" -lt 1 ] || [ "$BATCH_SIZE" -gt 10 ]; then
  echo "FATAL: BATCH_SIZE must be an integer from 1 to 10 (SQS batch limit)" >&2
  exit 1
fi

if ! [[ "$MAX_MESSAGES" =~ ^[0-9]+$ ]]; then
  echo "FATAL: MAX_MESSAGES must be a non-negative integer" >&2
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  QURL="${QURL:-dry-run-no-aws-queue}"
elif [ -z "${QURL:-}" ]; then
  QURL=$(aws sqs get-queue-url \
    --region "$REGION" \
    --queue-name "vendor-archive-${ENV}-vendor-events-q" \
    --query QueueUrl \
    --output text)
fi

if [ -n "${INTERVAL_SECONDS:-}" ]; then
  SLEEP_SECONDS="$INTERVAL_SECONDS"
else
  SLEEP_SECONDS=$(python3 - "$RATE_PER_MIN" "$BATCH_SIZE" <<'PY'
import sys
rate = int(sys.argv[1])
batch = int(sys.argv[2])
print(max(0.1, (60.0 * batch) / rate))
PY
)
fi

TMP_ENTRIES="$(mktemp)"
trap 'rm -f "$TMP_ENTRIES"' EXIT

make_entries() {
  python3 - "$1" "$ENV" <<'PY'
import hashlib
import json
import random
import sys
import uuid
from datetime import datetime, timezone

count = int(sys.argv[1])
environment = sys.argv[2]

services = ["identity-api", "los-api", "payment-api"]
stages = [
    "LEAD", "SELFIE", "KYC", "PAN_AADHAAR_SEED", "LOCATION_BRE", "BUREAU_BRE",
    "BANK_BRE", "REPEAT_BRE", "UNDERWRITING", "DISBURSED", "REPAID",
    "OVERDUE", "CLOSED", "WRITTEN_OFF", "LMS_QUERY", "PENNY_DROP",
    "LOAN_AGREEMENT", "DISBURSEMENT",
]
vendor_profiles = [
    {
        "vendor_id": "karza",
        "endpoints": ["/kyc/verify", "/pan/validate", "/aadhaar/otp"],
        "stages": ["KYC", "PAN_AADHAAR_SEED"],
        "base_cost": 150,
        "latency": (90, 450),
        "success_weight": 86,
    },
    {
        "vendor_id": "digitap",
        "endpoints": ["/bank/statement", "/bank/analyse", "/account/insights"],
        "stages": ["BANK_BRE", "UNDERWRITING"],
        "base_cost": 300,
        "latency": (450, 2200),
        "success_weight": 82,
    },
    {
        "vendor_id": "signzy",
        "endpoints": ["/pan/validate", "/ckyc/search", "/face/match"],
        "stages": ["KYC", "SELFIE", "PAN_AADHAAR_SEED"],
        "base_cost": 75,
        "latency": (70, 900),
        "success_weight": 78,
    },
    {
        "vendor_id": "easebuzz",
        "endpoints": ["/payout", "/penny-drop", "/disbursement/status"],
        "stages": ["PENNY_DROP", "DISBURSEMENT", "DISBURSED"],
        "base_cost": 200,
        "latency": (180, 1800),
        "success_weight": 88,
    },
    {
        "vendor_id": "crif",
        "endpoints": ["/bureau/pull", "/score/fetch", "/report/download"],
        "stages": ["BUREAU_BRE", "REPEAT_BRE"],
        "base_cost": 500,
        "latency": (700, 4200),
        "success_weight": 74,
    },
    {
        "vendor_id": "nsdl",
        "endpoints": ["/aadhaar/seed", "/pan/status", "/demographic/verify"],
        "stages": ["PAN_AADHAAR_SEED", "KYC"],
        "base_cost": 120,
        "latency": (120, 750),
        "success_weight": 84,
    },
    {
        "vendor_id": "synoriq",
        "endpoints": ["/lms/query", "/loan/status", "/repayment/schedule"],
        "stages": ["LMS_QUERY", "REPAID", "OVERDUE", "CLOSED"],
        "base_cost": 40,
        "latency": (60, 350),
        "success_weight": 92,
    },
    {
        "vendor_id": "icici-bank",
        "endpoints": ["/nach/status", "/penny-drop", "/disbursement"],
        "stages": ["PENNY_DROP", "DISBURSEMENT", "DISBURSED"],
        "base_cost": 90,
        "latency": (140, 1200),
        "success_weight": 87,
    },
    {
        "vendor_id": "internal-bre",
        "endpoints": ["/bre/score", "/bre/decision", "/risk/rules"],
        "stages": ["LOCATION_BRE", "BUREAU_BRE", "BANK_BRE", "UNDERWRITING"],
        "base_cost": 5,
        "latency": (25, 180),
        "success_weight": 95,
    },
    {
        "vendor_id": "bank-statement-analyser",
        "endpoints": ["/statement/analyse", "/statement/fraud-check"],
        "stages": ["BANK_BRE", "UNDERWRITING"],
        "base_cost": 250,
        "latency": (500, 3000),
        "success_weight": 80,
    },
]

first_names = ["Amit", "Priya", "Rakesh", "Neha", "Sanjay", "Anita", "Vikram", "Pooja"]
last_names = ["Sharma", "Verma", "Kumar", "Patel", "Singh", "Rao", "Iyer", "Gupta"]
error_codes = {
    "FAILURE": ["VALIDATION_FAILED", "VENDOR_REJECTED", "BAD_REQUEST", "NO_DATA"],
    "TIMEOUT": ["VENDOR_TIMEOUT", "UPSTREAM_TIMEOUT"],
    "NETWORK_ERROR": ["ECONNRESET", "ENOTFOUND", "TLS_HANDSHAKE_FAILED"],
}

def pan_for(i):
    letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    return "".join(random.choice(letters) for _ in range(5)) + f"{i % 10000:04d}" + random.choice(letters)

def mask_pan(pan):
    return pan[:3] + "****" + pan[-2:]

def mobile_for(i):
    return "9" + f"{random.randint(100000000, 999999999):09d}"[:-4] + f"{i % 10000:04d}"

def sha256(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()

def weighted_status(success_weight):
    failure_weight = max(1, 100 - success_weight)
    return random.choices(
        ["SUCCESS", "FAILURE", "TIMEOUT", "NETWORK_ERROR"],
        weights=[success_weight, failure_weight * 0.55, failure_weight * 0.25, failure_weight * 0.20],
        k=1,
    )[0]

def http_status_for(status):
    if status == "SUCCESS":
        return random.choice([200, 200, 200, 201, 202])
    if status == "FAILURE":
        return random.choice([400, 401, 403, 409, 422, 429, 500, 502])
    return 0

def latency_for(profile, status):
    if status == "TIMEOUT":
        return random.choice([10000, 15000, 30000])
    low, high = profile["latency"]
    if status in ("FAILURE", "NETWORK_ERROR"):
        high = int(high * 1.8)
    return random.randint(low, high)

entries = []
for idx in range(count):
    request_id = str(uuid.uuid4())
    profile = random.choice(vendor_profiles)
    status = weighted_status(profile["success_weight"])
    http_status = http_status_for(status)
    latency_ms = latency_for(profile, status)
    pan = pan_for(random.randint(1000, 999999))
    mobile = mobile_for(random.randint(1000, 999999))
    aadhaar_last4 = f"{random.randint(0, 9999):04d}"
    name = f"{random.choice(first_names)} {random.choice(last_names)}"
    user_number = random.randint(1000, 9999)
    user_id = random.choice(["dheeraj", f"user-{user_number}", f"borrower-{user_number}"])
    lan = "" if random.random() < 0.25 else f"LAN-{datetime.now(timezone.utc).year}-{random.randint(100000, 999999)}"
    request_payload = {
        "pan": pan,
        "mobile": mobile,
        "email": f"{name.lower().replace(' ', '.')}@example.com",
        "name": name,
        "loanAmount": random.choice([25000, 50000, 75000, 100000, 150000, 250000]),
        "consent": random.choice([True, True, True, False]),
    }
    response_payload = (
        {"ok": True, "vendorRefId": f"{profile['vendor_id'].upper()}-{random.randint(100000, 999999)}", "aadhaarLast4": aadhaar_last4}
        if status == "SUCCESS"
        else {"ok": False, "error": random.choice(error_codes[status]), "retryable": status != "FAILURE"}
    )
    req_string = json.dumps(request_payload, separators=(",", ":"))
    resp_string = json.dumps(response_payload, separators=(",", ":"))
    event = {
        "schema_version": 1,
        "request_id": request_id,
        "correlation_id": "stream-" + request_id[:8],
        "created_at": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "service": random.choice(services),
        "environment": environment,
        "vendor_id": profile["vendor_id"],
        "endpoint": random.choice(profile["endpoints"]),
        "vendor_ref_id": response_payload.get("vendorRefId", ""),
        "loan_lifecycle_stage": random.choice(profile.get("stages", stages)),
        "loan_application_number": lan,
        "user_id": user_id,
        "pan_masked": mask_pan(pan),
        "mobile_hash": sha256("+91" + mobile),
        "mobile_last4": mobile[-4:],
        "aadhaar_last4_hash": sha256(aadhaar_last4),
        "consent_id": f"consent-{random.randint(10000, 99999)}",
        "status": status,
        "http_status": http_status,
        "latency_ms": latency_ms,
        "cost_paise": max(0, profile["base_cost"] + random.randint(-20, 80)),
        "error_code": "" if status == "SUCCESS" else response_payload["error"],
        "error_message": "" if status == "SUCCESS" else f"{profile['vendor_id']} returned {response_payload['error']}",
        "request_payload": req_string,
        "response_payload": resp_string,
        "payload_truncated": False,
        "request_hash": sha256(req_string),
    }
    entries.append({"Id": str(idx), "MessageBody": json.dumps(event, separators=(",", ":"))})

print(json.dumps(entries))
PY
}

sent=0
batch_no=0

echo "Streaming random vendor events"
echo "  env=$ENV region=$REGION batch_size=$BATCH_SIZE rate_per_min=$RATE_PER_MIN sleep=${SLEEP_SECONDS}s"
echo "  queue=$QURL"
echo "  stop with Ctrl-C"

while true; do
  remaining="$BATCH_SIZE"
  if [ "$MAX_MESSAGES" -gt 0 ]; then
    left=$((MAX_MESSAGES - sent))
    [ "$left" -le 0 ] && break
    [ "$left" -lt "$remaining" ] && remaining="$left"
  fi

  make_entries "$remaining" > "$TMP_ENTRIES"

  if [ "$DRY_RUN" = "1" ]; then
    python3 -m json.tool "$TMP_ENTRIES"
    echo "DRY_RUN=1, not sending."
    exit 0
  fi

  aws sqs send-message-batch \
    --region "$REGION" \
    --queue-url "$QURL" \
    --entries "file://$TMP_ENTRIES" \
    --output text >/dev/null

  sent=$((sent + remaining))
  batch_no=$((batch_no + 1))
  printf 'sent batch=%d messages=%d total=%d\n' "$batch_no" "$remaining" "$sent"

  if [ "$MAX_MESSAGES" -gt 0 ] && [ "$sent" -ge "$MAX_MESSAGES" ]; then
    break
  fi

  sleep "$SLEEP_SECONDS"
done

echo "Done. total_sent=$sent"
