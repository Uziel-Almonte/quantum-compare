#!/usr/bin/env bash
# Unified TLS experiment: classical vs PQC under IDENTICAL conditions.
# Same 150 KB page, curl measurement, tc netem latency, 60 runs, one CSV schema.
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
unset OPENSSL_CONF OPENSSL_MODULES LD_LIBRARY_PATH PKG_CONFIG_PATH 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXP="$ROOT/experiment"
# shellcheck source=/dev/null
source "$EXP/config.env"

WWW_DIR="$EXP/www"
CERT_DIR="$EXP/certs"
DATA_DIR="$EXP/data"
PAGE_PATH="$WWW_DIR/$PAGE_FILE"
EXPECTED_BYTES=$((PAGE_SIZE_KB * 1024))
CSV_OUT="${CSV_OUT:-$DATA_DIR/results.csv}"
MANIFEST="$DATA_DIR/manifest.txt"
PID_FILE="$DATA_DIR/server.pid"
LOG_FILE="$DATA_DIR/server.log"
NETEM_APPLIED=0

CL_CA="$CERT_DIR/classical/ca.crt"
CL_CERT="$CERT_DIR/classical/server.crt"
CL_KEY="$CERT_DIR/classical/server.key"
PQ_CA="$CERT_DIR/pqc/ca.crt"
PQ_CERT="$CERT_DIR/pqc/server.crt"
PQ_KEY="$CERT_DIR/pqc/server.key"

need_tools() {
  for t in openssl curl bc awk dd; do
    command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 1; }
  done
  local ver; ver="$(openssl version | awk '{print $2}')"
  local major="${ver%%.*}" minor="${ver#*.}"; minor="${minor%%.*}"
  if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 5 ]; }; then
    echo "OpenSSL >= 3.5 required for PQC arm (found $ver)" >&2; exit 1
  fi
}

LATENCY_METHOD=""

latency_on() {
  if sudo -n tc qdisc replace dev lo root netem delay "${SIM_LATENCY_MS}ms" >/dev/null 2>&1; then
    NETEM_APPLIED=1
    LATENCY_METHOD="tc-netem"
    echo "==> Simulated latency ON: lo netem delay ${SIM_LATENCY_MS}ms (one-way)"
  else
    LATENCY_METHOD="client-sleep"
    echo "==> Simulated latency ON: client sleep ${SIM_LATENCY_MS}ms before each request (tc unavailable)"
  fi
}

apply_client_latency() {
  if [ "$LATENCY_METHOD" = "client-sleep" ]; then
    sleep "$(echo "scale=6; $SIM_LATENCY_MS / 1000" | bc)"
  fi
}

latency_off() {
  if [ "$NETEM_APPLIED" -eq 1 ]; then
    sudo -n tc qdisc del dev lo root >/dev/null 2>&1 || true
    NETEM_APPLIED=0
    echo "==> Simulated latency OFF"
  fi
}

trap 'latency_off' EXIT

write_manifest() {
  mkdir -p "$DATA_DIR"
  {
    echo "experiment=quantum-compare"
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "page_size_kb=$PAGE_SIZE_KB"
    echo "page_bytes=$EXPECTED_BYTES"
    echo "page_file=$PAGE_FILE"
    echo "iterations=$ITERATIONS"
    echo "sim_latency_ms=$SIM_LATENCY_MS"
    echo "latency_method=${LATENCY_METHOD:-pending}"
    echo "measure_tool=$MEASURE_TOOL"
    echo "port=$PORT"
    echo "classical_groups=$CLASSICAL_GROUPS"
    echo "classical_sigalgs=$CLASSICAL_SIGALGS"
    echo "pqc_groups=$PQC_GROUPS"
    echo "pqc_sigalgs=$PQC_SIGALGS"
    echo "csv_schema=timestamp,mode,iteration,sim_latency_ms,page_bytes,downloaded_bytes,connect_ms,appconnect_ms,total_ms,tls_group,signature,success"
  } >"$MANIFEST"
}

cmd_setup() {
  need_tools
  mkdir -p "$WWW_DIR" "$CERT_DIR/classical" "$CERT_DIR/pqc" "$DATA_DIR"

  echo "==> Creating ${PAGE_SIZE_KB} KB page ($EXPECTED_BYTES bytes)..."
  dd if=/dev/zero of="$PAGE_PATH" bs=1024 count="$PAGE_SIZE_KB" status=none
  local actual; actual="$(wc -c <"$PAGE_PATH")"
  [ "$actual" -eq "$EXPECTED_BYTES" ] || { echo "page size mismatch: $actual" >&2; exit 1; }

  echo "==> Classical certs (ECDSA P-256 + X25519)..."
  openssl ecparam -name prime256v1 -genkey -noout -out "$CERT_DIR/classical/ca.key"
  openssl req -new -x509 -key "$CERT_DIR/classical/ca.key" -out "$CL_CA" -days 365 \
    -subj "/CN=Classical-CA/O=quantum-compare/C=US"
  openssl ecparam -name prime256v1 -genkey -noout -out "$CL_KEY"
  openssl req -new -key "$CL_KEY" -out "$CERT_DIR/classical/server.csr" \
    -subj "/CN=classical-server.local/O=quantum-compare/C=US"
  openssl x509 -req -in "$CERT_DIR/classical/server.csr" -CA "$CL_CA" -CAkey "$CERT_DIR/classical/ca.key" \
    -CAcreateserial -out "$CL_CERT" -days 365

  echo "==> PQC certs (ML-DSA-65)..."
  openssl genpkey -algorithm ML-DSA-65 -out "$CERT_DIR/pqc/ca.key"
  openssl req -new -x509 -key "$CERT_DIR/pqc/ca.key" -out "$PQ_CA" -days 365 \
    -subj "/CN=PQC-CA/O=quantum-compare/C=US"
  openssl genpkey -algorithm ML-DSA-65 -out "$PQ_KEY"
  openssl req -new -key "$PQ_KEY" -out "$CERT_DIR/pqc/server.csr" \
    -subj "/CN=pqc-server.local/O=quantum-compare/C=US"
  openssl x509 -req -in "$CERT_DIR/pqc/server.csr" -CA "$PQ_CA" -CAkey "$CERT_DIR/pqc/ca.key" \
    -CAcreateserial -out "$PQ_CERT" -days 365

  write_manifest
  echo "==> Setup complete"
}

stop_server() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
}

start_server() {
  local mode="$1" cert="$2" key="$3" groups="$4" sigalgs="${5:-}"
  stop_server
  sleep 0.5
  echo "==> Server [$mode] :$PORT groups=$groups${sigalgs:+ sig=$sigalgs}"
  local extra=()
  [ -n "$sigalgs" ] && extra=(-sigalgs "$sigalgs")
  (cd "$WWW_DIR" && exec openssl s_server -accept "$PORT" -WWW \
    -min_protocol TLSv1.3 -max_protocol TLSv1.3 \
    -cert "$cert" -key "$key" \
    -groups "$groups" "${extra[@]}" \
    >"$LOG_FILE" 2>&1) &
  echo $! >"$PID_FILE"
  sleep 1
  kill -0 "$(cat "$PID_FILE")" || { cat "$LOG_FILE" >&2; exit 1; }
}

# Single measurement using curl (same tool for both arms).
measure_once() {
  local mode="$1" iteration="$2" ca="$3" groups="$4"
  local ts curl_out connect app total size ok=0 group sig
  local hs_tmp; hs_tmp="$(mktemp)"

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  apply_client_latency
  curl_out="$(curl -sk --tlsv1.3 --curves "$groups" \
    --cacert "$ca" \
    -o /dev/null \
    -w "%{time_connect},%{time_appconnect},%{time_total},%{size_download}" \
    "https://127.0.0.1:${PORT}/${PAGE_FILE}" 2>/dev/null)" || true

  IFS=, read -r connect app total size <<<"$curl_out"
  [ "${size:-0}" -eq "$EXPECTED_BYTES" ] && ok=1

  openssl s_client -connect "127.0.0.1:$PORT" -tls1_3 \
    -CAfile "$ca" -groups "$groups" </dev/null >"$hs_tmp" 2>&1 || true
  group="$(grep -i 'Negotiated TLS1.3 group:' "$hs_tmp" | awk '{print $NF}')"
  if [ -z "$group" ]; then
    group="$(grep -i 'Peer Temp Key:' "$hs_tmp" | awk -F: '{print $2}' | awk '{print $1}')"
  fi
  group="${group%,}"
  sig="$(grep -iE 'Peer signature type:|Signature type:' "$hs_tmp" | tail -1 | awk '{print $NF}')"
  rm -f "$hs_tmp"

  # Validate algorithm family per mode
  if [ "$mode" = "pqc" ]; then
    case "$group" in MLKEM512|MLKEM768|MLKEM1024) ;; *) ok=0 ;; esac
    case "$sig" in mldsa44|mldsa65|mldsa87) ;; *) ok=0 ;; esac
  else
    case "$group" in X25519|secp256r1|secp384r1|x25519) ;; *) ok=0 ;; esac
    case "$sig" in ecdsa*|rsa*|ECDSA*) ;; *) ok=0 ;; esac
  fi

  connect_ms="$(echo "scale=3; ${connect:-0} * 1000" | bc)"
  app_ms="$(echo "scale=3; ${app:-0} * 1000" | bc)"
  total_ms="$(echo "scale=3; ${total:-0} * 1000" | bc)"

  echo "${ts},${mode},${iteration},${SIM_LATENCY_MS},${EXPECTED_BYTES},${size:-0},${connect_ms},${app_ms},${total_ms},${group:-},${sig:-},${ok}"
}

run_arm() {
  local mode="$1" cert="$2" key="$3" ca="$4" groups="$5" sigalgs="$6"
  start_server "$mode" "$cert" "$key" "$groups" "$sigalgs"
  local i row
  for i in $(seq 1 "$ITERATIONS"); do
    row="$(measure_once "$mode" "$i" "$ca" "$groups")"
    echo "$row" >>"$CSV_OUT"
    printf "\r  [%s] %d/%d" "$mode" "$i" "$ITERATIONS"
  done
  echo
  stop_server
}

summarize() {
  local out="$DATA_DIR/summary.txt"
  awk -F, '
    NR==1 { next }
    $12==1 {
      m=$2; c[m]++; t[m]+=$9
      if (!(m SUBSEP "init" in seen)) { min[m]=$9; max[m]=$9; seen[m SUBSEP "init"]=1 }
      if ($9 < min[m]) min[m]=$9
      if ($9 > max[m]) max[m]=$9
      g[m]=$10; s[m]=$11
    }
    END {
      for (m in c) {
        printf "mode=%s\nsamples=%d\ntotal_ms_mean=%.3f\ntotal_ms_min=%.3f\ntotal_ms_max=%.3f\ntls_group=%s\nsignature=%s\n\n",
          m, c[m], t[m]/c[m], min[m], max[m], g[m], s[m]
      }
    }
  ' "$CSV_OUT" | sort >"$out"
  echo "==> Summary: $out"
  cat "$out"
}

cmd_run() {
  need_tools
  [ -f "$PAGE_PATH" ] || { echo "Run: $0 setup" >&2; exit 1; }

  mkdir -p "$DATA_DIR"
  write_manifest
  latency_on
  # Refresh manifest with latency method
  write_manifest

  echo "timestamp,mode,iteration,sim_latency_ms,page_bytes,downloaded_bytes,connect_ms,appconnect_ms,total_ms,tls_group,signature,success" >"$CSV_OUT"

  echo "==> Classical arm ($ITERATIONS runs)..."
  run_arm classical "$CL_CERT" "$CL_KEY" "$CL_CA" "$CLASSICAL_GROUPS" "$CLASSICAL_SIGALGS"

  echo "==> PQC arm ($ITERATIONS runs)..."
  run_arm pqc "$PQ_CERT" "$PQ_KEY" "$PQ_CA" "$PQC_GROUPS" "$PQC_SIGALGS"

  summarize
  echo "==> Results: $CSV_OUT"
  echo "==> Manifest: $MANIFEST"
}

cmd_all() {
  cmd_setup
  cmd_run
}

usage() {
  cat <<EOF
Usage: $0 <command>

  setup   Create 150 KB page + classical/PQC certs
  run     Run 60 identical measurements per arm (needs setup)
  all     setup + run

Shared config: experiment/config.env
  PAGE_SIZE_KB=$PAGE_SIZE_KB  ITERATIONS=$ITERATIONS  SIM_LATENCY_MS=$SIM_LATENCY_MS
EOF
}

case "${1:-}" in
  setup) cmd_setup ;;
  run)   cmd_run ;;
  all)   cmd_all ;;
  *)     usage; exit 1 ;;
esac
