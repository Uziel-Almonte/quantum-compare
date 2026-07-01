#!/usr/bin/env bash
# validate_pilot.sh — Automated checks for the pilot run (Fase 3).
# Run this right after a small pilot (`experiment/run.sh all` with a low
# ITERATIONS) and before committing to the full 60/60 run.
#
# Usage:
#   bash validate_pilot.sh [experiment/data directory]
#
# Exits 0 if every check passes, 1 if any check fails.

set -uo pipefail

DATA_DIR="${1:-experiment/data}"
CSV="$DATA_DIR/results.csv"
ORDER="$DATA_DIR/order.txt"

PASS=0
FAIL=0

check() {
  local label="$1" ok="$2" detail="$3"
  if [ "$ok" -eq 1 ]; then
    echo "  [OK]   $label"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $label -- $detail"
    FAIL=$((FAIL + 1))
  fi
}

echo "==================================================="
echo " Pilot validation — $CSV"
echo "==================================================="

if [ ! -f "$CSV" ]; then
  echo "results.csv not found at $CSV. Run the pilot first." >&2
  exit 1
fi

# Expected trials = rows in CSV (minus header)
TOTAL_ROWS=$(($(wc -l <"$CSV") - 1))
if [ "$TOTAL_ROWS" -le 0 ]; then
  echo "results.csv has no data rows." >&2
  exit 1
fi

echo
echo "--- 1. Row count ---"
echo "  Data rows found: $TOTAL_ROWS"
check "at least 1 row per arm present" \
  "$( [ "$TOTAL_ROWS" -ge 2 ] && echo 1 || echo 0 )" \
  "expected >=2 rows (>=1 classical + >=1 pqc), got $TOTAL_ROWS"

echo
echo "--- 2. Success rate (column 12) ---"
FAIL_COUNT=$(awk -F, 'NR>1 && $12!=1 {c++} END{print c+0}' "$CSV")
awk -F, 'NR>1 {print $12}' "$CSV" | sort | uniq -c | sed 's/^/  /'
check "all rows success=1" \
  "$( [ "$FAIL_COUNT" -eq 0 ] && echo 1 || echo 0 )" \
  "$FAIL_COUNT row(s) with success=0 -- check tls_group/signature on those rows"

echo
echo "--- 3. Group balance (column 2: mode) ---"
awk -F, 'NR>1 {print $2}' "$CSV" | sort | uniq -c | sed 's/^/  /'
CL_COUNT=$(awk -F, 'NR>1 && $2=="classical" {c++} END{print c+0}' "$CSV")
PQ_COUNT=$(awk -F, 'NR>1 && $2=="pqc" {c++} END{print c+0}' "$CSV")
check "both arms present (classical>0 and pqc>0)" \
  "$( [ "$CL_COUNT" -gt 0 ] && [ "$PQ_COUNT" -gt 0 ] && echo 1 || echo 0 )" \
  "classical=$CL_COUNT pqc=$PQ_COUNT"

echo
echo "--- 4. Algorithm correctness per mode (columns 10/11: tls_group, signature) ---"
BAD_CLASSICAL=$(awk -F, 'NR>1 && $2=="classical" && $10!~/^(X25519|secp256r1|secp384r1|x25519)$/ {c++} END{print c+0}' "$CSV")
BAD_CLASSICAL_SIG=$(awk -F, 'NR>1 && $2=="classical" && $11!~/^(ecdsa|rsa|ECDSA)/ {c++} END{print c+0}' "$CSV")
BAD_PQC=$(awk -F, 'NR>1 && $2=="pqc" && $10!~/^(MLKEM512|MLKEM768|MLKEM1024)$/ {c++} END{print c+0}' "$CSV")
BAD_PQC_SIG=$(awk -F, 'NR>1 && $2=="pqc" && $11!~/^mldsa(44|65|87)$/ {c++} END{print c+0}' "$CSV")

check "classical rows use X25519/secp* key exchange" \
  "$( [ "$BAD_CLASSICAL" -eq 0 ] && echo 1 || echo 0 )" \
  "$BAD_CLASSICAL classical row(s) with unexpected tls_group"
check "classical rows use ECDSA/RSA signature" \
  "$( [ "$BAD_CLASSICAL_SIG" -eq 0 ] && echo 1 || echo 0 )" \
  "$BAD_CLASSICAL_SIG classical row(s) with unexpected signature"
check "pqc rows use MLKEM key exchange" \
  "$( [ "$BAD_PQC" -eq 0 ] && echo 1 || echo 0 )" \
  "$BAD_PQC pqc row(s) with unexpected tls_group -- possible silent fallback!"
check "pqc rows use mldsa signature" \
  "$( [ "$BAD_PQC_SIG" -eq 0 ] && echo 1 || echo 0 )" \
  "$BAD_PQC_SIG pqc row(s) with unexpected signature -- possible silent fallback!"

echo
echo "--- 5. Randomized order (order.txt must NOT be run in fixed blocks) ---"
if [ ! -f "$ORDER" ]; then
  echo "  [SKIP] order.txt not found at $ORDER (older script version?)"
else
  echo "  Sequence found in order.txt:"
  cat "$ORDER" | sed 's/^/    /'
  echo
  awk -F, 'NR>1{print $2}' "$CSV" > /dev/null # no-op, keep CSV untouched

  # Longest consecutive run of the same mode in order.txt
  MAX_RUN=$(awk '
    NR==1 { prev=$0; run=1; maxrun=1; next }
    $0==prev { run++; if (run>maxrun) maxrun=run; next }
    { prev=$0; run=1 }
    END { print maxrun+0 }
  ' "$ORDER")

  N_TRIALS=$(wc -l <"$ORDER")
  # Heuristic threshold: a run longer than ~40% of total trials suggests
  # the order is not actually randomized (e.g. still in two fixed blocks).
  THRESHOLD=$(( (N_TRIALS * 4 + 9) / 10 ))
  echo "  Longest consecutive same-mode run: $MAX_RUN (out of $N_TRIALS trials)"

  check "order is interleaved, not run in one large fixed block" \
    "$( [ "$MAX_RUN" -lt "$THRESHOLD" ] && echo 1 || echo 0 )" \
    "longest run ($MAX_RUN) is suspiciously close to total trials ($N_TRIALS) -- looks like fixed blocks, not random order"

  # Cross-check: order.txt sequence should match CSV mode sequence 1:1
  ORDER_SEQ=$(cat "$ORDER")
  CSV_SEQ=$(awk -F, 'NR>1{print $2}' "$CSV")
  check "order.txt matches the actual mode sequence in results.csv" \
    "$( [ "$ORDER_SEQ" = "$CSV_SEQ" ] && echo 1 || echo 0 )" \
    "order.txt and results.csv mode sequence do not match -- investigate run.sh"
fi

echo
echo "==================================================="
echo " Summary: $PASS passed, $FAIL failed"
echo "==================================================="

if [ "$FAIL" -gt 0 ]; then
  echo "Do NOT proceed to the full 60/60 run until every check above passes."
  exit 1
else
  echo "Pilot looks good. Safe to bump ITERATIONS back to 60 and run the full experiment."
  exit 0
fi
