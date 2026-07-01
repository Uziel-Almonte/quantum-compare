#!/usr/bin/env bash
# Lightweight PQC-only TLS lab (ML-KEM / Kyber + ML-DSA / Dilithium).
# Stack: bash + openssl 3.5+ only. No liboqs build, no Python, no nginx.
set -euo pipefail

# System OpenSSL only — no liboqs/oqs-provider env from prior sessions.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
unset OPENSSL_CONF OPENSSL_MODULES LD_LIBRARY_PATH PKG_CONFIG_PATH 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PQC_DIR="$ROOT/pqc"
CERT_DIR="${CERT_DIR:-$PQC_DIR/certs}"
DATA_DIR="${DATA_DIR:-$PQC_DIR/data}"
PORT="${PORT:-7443}"
KEM_GROUP="${KEM_GROUP:-MLKEM768}"   # pure ML-KEM (not X25519MLKEM768)
SIG_ALG="${SIG_ALG:-mldsa65}"        # ML-DSA-65 (Dilithium)
ML_DSA="${ML_DSA:-ML-DSA-65}"
ITERATIONS="${ITERATIONS:-30}"
WARMUP="${WARMUP:-5}"

CA_CRT="$CERT_DIR/ca.crt"
CA_KEY="$CERT_DIR/ca.key"
SRV_CRT="$CERT_DIR/server.crt"
SRV_KEY="$CERT_DIR/server.key"
PID_FILE="$DATA_DIR/server.pid"
LOG_FILE="$DATA_DIR/server.log"
VAL_OUT="$DATA_DIR/validation.txt"
CSV_OUT="$DATA_DIR/pqc-benchmark.csv"
SUM_OUT="$DATA_DIR/pqc-summary.txt"

need_openssl() {
  command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
  local ver
  ver="$(openssl version | awk '{print $2}')"
  local major minor
  major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
  if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 5 ]; }; then
    echo "Need OpenSSL >= 3.5 (found $ver). ML-KEM/ML-DSA are built in." >&2
    exit 1
  fi
}

cmd_setup() {
  need_openssl
  mkdir -p "$CERT_DIR" "$DATA_DIR"
  echo "==> OpenSSL $(openssl version | awk '{print $2}')"
  echo "==> Generating ML-DSA certs ($ML_DSA)..."
  openssl genpkey -algorithm "$ML_DSA" -out "$CA_KEY"
  openssl req -new -x509 -key "$CA_KEY" -out "$CA_CRT" -days 365 \
    -subj "/CN=PQC-CA/O=quantum-compare/C=US"
  openssl genpkey -algorithm "$ML_DSA" -out "$SRV_KEY"
  openssl req -new -key "$SRV_KEY" -out "$CERT_DIR/server.csr" \
    -subj "/CN=pqc-server.local/O=quantum-compare/C=US"
  openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$SRV_CRT" -days 365
  echo "==> Certs ready in $CERT_DIR"
}

cmd_serve() {
  need_openssl
  [ -f "$SRV_CRT" ] || { echo "Run: $0 setup" >&2; exit 1; }
  mkdir -p "$DATA_DIR"
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Server already on port $PORT (PID $(cat "$PID_FILE"))"
    exit 0
  fi
  echo "==> PQC TLS server :$PORT  kem=$KEM_GROUP  sig=$SIG_ALG"
  nohup openssl s_server -accept "$PORT" -www \
    -min_protocol TLSv1.3 -max_protocol TLSv1.3 \
    -cert "$SRV_CRT" -key "$SRV_KEY" \
    -groups "$KEM_GROUP" -sigalgs "$SIG_ALG" \
    >"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 1
  kill -0 "$(cat "$PID_FILE")" || { cat "$LOG_FILE" >&2; exit 1; }
  echo "==> PID $(cat "$PID_FILE")"
}

cmd_stop() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null && echo "Stopped $(cat "$PID_FILE")"
    rm -f "$PID_FILE"
  else
    echo "No server running"
  fi
}

handshake() {
  local tmp="${1:-$(mktemp)}"
  local owned="${2:-1}"
  openssl s_client -connect "localhost:$PORT" -tls1_3 \
    -CAfile "$CA_CRT" -groups "$KEM_GROUP" -sigalgs "$SIG_ALG" \
    </dev/null >"$tmp" 2>&1
  local rc=$?
  [ "$owned" -eq 1 ] || return $rc
  cat "$tmp"
  rm -f "$tmp"
  return $rc
}

cmd_validate() {
  need_openssl
  [ -f "$CA_CRT" ] || { echo "Run: $0 setup" >&2; exit 1; }
  mkdir -p "$DATA_DIR"
  local tmp; tmp="$(mktemp)"
  handshake "$tmp" 0 || { cat "$tmp" >&2; rm -f "$tmp"; exit 1; }

  local sig group
  sig="$(grep -iE 'Peer signature type:|Signature type:' "$tmp" | tail -1 | awk '{print $NF}')"
  group="$(grep -i 'Negotiated TLS1.3 group:' "$tmp" | awk '{print $NF}')"

  {
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "kem=$group"
    echo "signature=$sig"
    echo "expected_kem=$KEM_GROUP"
    echo "expected_sig=$SIG_ALG"
  } >"$VAL_OUT"

  rm -f "$tmp"
  case "$group" in MLKEM512|MLKEM768|MLKEM1024) ;; *)
    echo "FAIL: group=$group (not pure ML-KEM)" >&2; exit 1 ;; esac
  case "$sig" in mldsa44|mldsa65|mldsa87) ;; *)
    echo "FAIL: sig=$sig (not ML-DSA)" >&2; exit 1 ;; esac
  echo "PASS: pure PQC handshake (ML-KEM + ML-DSA)"
  cat "$VAL_OUT"
}

cmd_bench() {
  need_openssl
  mkdir -p "$DATA_DIR"
  echo "iteration,warmup,latency_ms,bytes_read,bytes_written,group,signature,success" >"$CSV_OUT"

  local i tmp start end ms sig group bread bwritten ok
  for i in $(seq 1 $((WARMUP + ITERATIONS))); do
    tmp="$(mktemp)"
    start="$(date +%s%N)"
    if handshake "$tmp" 0; then ok=1; else ok=0; fi
    end="$(date +%s%N)"
    ms="$(echo "scale=3; ($end - $start) / 1000000" | bc)"
    sig="$(grep -iE 'Peer signature type:|Signature type:' "$tmp" | tail -1 | awk '{print $NF}')"
    group="$(grep -i 'Negotiated TLS1.3 group:' "$tmp" | awk '{print $NF}')"
    bread="$(grep -i 'SSL handshake has read' "$tmp" | sed -n 's/.*read \([0-9]*\) bytes.*/\1/p')"
    bwritten="$(grep -i 'SSL handshake has read' "$tmp" | sed -n 's/.*written \([0-9]*\) bytes.*/\1/p')"
    rm -f "$tmp"
    case "$group" in MLKEM512|MLKEM768|MLKEM1024) ;; *) ok=0 ;; esac
    case "$sig" in mldsa44|mldsa65|mldsa87) ;; *) ok=0 ;; esac
    local warmup=0; [ "$i" -le "$WARMUP" ] && warmup=1
    echo "$i,$warmup,$ms,${bread:-0},${bwritten:-0},$group,$sig,$ok" >>"$CSV_OUT"
    printf "\r  %d/%d" "$i" "$((WARMUP + ITERATIONS))"
  done
  echo

  awk -F, -v out="$SUM_OUT" -v n="$ITERATIONS" '
    NR==1 { next }
    $2==0 && $8==1 {
      lat[++c]=$3; r+= $4; w+=$5
    }
    END {
      if (c==0) { print "no successful samples" > "/dev/stderr"; exit 1 }
      min=max=lat[1]; sum=0
      for (i=1;i<=c;i++) {
        sum+=lat[i]
        if (lat[i]<min) min=lat[i]
        if (lat[i]>max) max=lat[i]
      }
      mean=sum/c
      for (i=1;i<=c;i++) sq+=(lat[i]-mean)^2
      stdev=(c>1)?sqrt(sq/c):0
      printf "label=pqc-only\nkem=ML-KEM-768\nsignature=ML-DSA-65\nsamples=%d\nlatency_ms_min=%.3f\nlatency_ms_max=%.3f\nlatency_ms_mean=%.3f\nlatency_ms_stdev=%.3f\nbytes_read_mean=%.0f\nbytes_written_mean=%.0f\n",
        c, min, max, mean, stdev, r/c, w/c > out
      print "==> Summary written to " out
      while ((getline line < out) > 0) print line
      close(out)
    }
  ' "$CSV_OUT"
  echo "==> CSV: $CSV_OUT"
  cat "$SUM_OUT"
}

cmd_all() {
  cmd_setup
  cmd_stop 2>/dev/null || true
  cmd_serve
  sleep 1
  cmd_validate
  cmd_bench
}

cmd_check() {
  need_openssl
  echo "openssl: $(openssl version)"
  echo "note: OpenSSL 3.5+ includes ML-KEM (Kyber) and ML-DSA (Dilithium) natively — no liboqs build needed."
  openssl list -kem-algorithms 2>/dev/null | grep -i ml-kem | head -3
  openssl list -signature-algorithms 2>/dev/null | grep -i ml-dsa | head -3
  openssl list -tls-groups -tls1_3 2>/dev/null | tr ':' '\n' | grep -i '^MLKEM' || true
}

usage() {
  cat <<EOF
Usage: $0 <command>

  check     Verify OpenSSL 3.5+ has ML-KEM / ML-DSA
  setup     Generate ML-DSA certificates
  serve     Start PQC-only TLS server (openssl s_server)
  stop      Stop server
  validate  Confirm handshake uses pure PQC
  bench     Collect PQC-only benchmark CSV
  all       setup + serve + validate + bench

Env: PORT=$PORT  KEM_GROUP=$KEM_GROUP  SIG_ALG=$SIG_ALG  ITERATIONS=$ITERATIONS
EOF
}

case "${1:-}" in
  check)    cmd_check ;;
  setup)    cmd_setup ;;
  serve)    cmd_serve ;;
  stop)     cmd_stop ;;
  validate) cmd_validate ;;
  bench)    cmd_bench ;;
  all)      cmd_all ;;
  *)        usage; exit 1 ;;
esac
