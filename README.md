# quantum-compare

Investigation of post-quantum cryptography (PQC) vs classical TLS on modern systems.

**Algorithms covered:**
- **ML-KEM-768** (Kyber) — key exchange
- **ML-DSA-65** (Dilithium) — signatures

**Stack:** bash, OpenSSL 3.5+, curl, awk, bc. No liboqs build, no nginx, no Python required.

---

## Requirements

No `requirements.txt` — this project uses **system tools only** (no Python/Node packages). Install via your OS package manager:

```bash
# Debian/Ubuntu example
sudo apt install openssl curl bc awk coreutils
```

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| OpenSSL | **3.5+** | Native ML-KEM / ML-DSA support |
| curl | any (linked to OpenSSL 3.5+) | Page download + timing |
| bash, awk, bc, dd | system default | Scripts and stats |

Optional: `iproute2` (`tc`) for kernel-level latency simulation via `tc netem` (needs sudo).

Check your setup:

```bash
openssl version          # must be >= 3.5
curl --version           # should show OpenSSL/3.5.x
bash pqc/pqc.sh check    # lists available PQC algorithms
```

---

## Project layout

```
quantum-compare/
├── README.md
├── experiment/              # Controlled comparison (classical vs PQC)
│   ├── config.env           # Shared experiment parameters (DO NOT change per-arm)
│   ├── run.sh               # Main experiment runner
│   ├── www/                 # Generated 150 KB test page
│   ├── certs/               # Generated TLS certificates
│   └── data/                # Results (CSV, summary, manifest)
└── pqc/                     # PQC-only TLS lab (handshake benchmarks)
    ├── pqc.sh
    ├── certs/
    └── data/
```

---

## Quick start — controlled experiment (recommended)

This is the **main comparison** both teams should use. It enforces identical conditions:

| Parameter | Default |
|-----------|---------|
| Page size | 150 KB |
| Measurement tool | curl |
| Simulated latency | 50 ms |
| Iterations per arm | 60 |
| Output format | CSV (same schema for both arms) |

### Run everything

```bash
cd quantum-compare
bash experiment/run.sh all
```

This will:
1. Generate a 150 KB test page
2. Create classical (ECDSA + X25519) and PQC (ML-DSA + ML-KEM) certificates
3. Run 60 classical downloads, then 60 PQC downloads
4. Write results to `experiment/data/`

### Step by step

```bash
bash experiment/run.sh setup    # page + certs only
bash experiment/run.sh run      # benchmark only (requires setup)
```

### Output files

| File | Contents |
|------|----------|
| `experiment/data/results.csv` | All 120 rows (60 classical + 60 PQC) |
| `experiment/data/summary.txt` | Aggregated stats per arm |
| `experiment/data/manifest.txt` | Experiment parameters (proof of identical conditions) |

### CSV columns (`experiment/data/results.csv`)

Main comparison file: **120 rows** (60 classical + 60 PQC). Header:

```
timestamp,mode,iteration,sim_latency_ms,page_bytes,downloaded_bytes,
connect_ms,appconnect_ms,total_ms,tls_group,signature,success
```

| Column | Example | Meaning |
|--------|---------|---------|
| `timestamp` | `2026-07-01T21:00:03Z` | When the run happened (UTC) |
| `mode` | `classical` or `pqc` | Which arm ran — **primary column for grouping** |
| `iteration` | `1` … `60` | Run number within that arm |
| `sim_latency_ms` | `50` | Configured simulated delay (`config.env`). Same on every row |
| `page_bytes` | `153600` | Expected page size (150 × 1024). Same on every row |
| `downloaded_bytes` | `153600` | Bytes curl actually received |
| `connect_ms` | `0.179` | TCP connect time (`curl time_connect` × 1000) |
| `appconnect_ms` | `3.475` | Time until TLS handshake completes (`curl time_appconnect` × 1000). **≈ handshake latency** |
| `total_ms` | `4.055` | Full request: connect + TLS + 150 KB download (`curl time_total` × 1000). **Main speed metric** |
| `tls_group` | `X25519` or `MLKEM768` | Negotiated key exchange (proves which KEM was used) |
| `signature` | `ecdsa_secp256r1_sha256` or `mldsa65` | Server certificate signature algorithm |
| `success` | `1` or `0` | `1` only if download size matches **and** algorithms match the expected family |

**Timing relationship:**

```
connect_ms        → TCP only
appconnect_ms     → TCP + TLS handshake     ← compare handshake cost
total_ms          → TCP + TLS + 150 KB      ← compare full page load
total_ms - appconnect_ms ≈ transfer time after TLS is established
```

**`success=0` when:** wrong byte count, wrong KEM group, or wrong signature for that mode. Filter with `$12==1` before averaging.

**Example row:**

```
2026-07-01T21:00:03Z,classical,1,50,153600,153600,.179,3.475,4.055,X25519,ecdsa_secp256r1_sha256,1
```

→ Classical run #1, full 150 KB downloaded, handshake ~3.5 ms, total ~4.1 ms, X25519 + ECDSA, valid.

**Quick analysis:**

```bash
# Mean total time per mode (successful runs only)
awk -F, 'NR>1 && $12==1 {n[$2]++; s[$2]+=$9} END {for(m in n) printf "%s: %.3f ms\n", m, s[m]/n[m]}' \
  experiment/data/results.csv

# Success count per mode
awk -F, 'NR>1 {print $2, $12}' experiment/data/results.csv | sort | uniq -c
```

### CSV columns (`pqc/data/pqc-benchmark.csv`)

PQC handshake-only lab from `pqc/pqc.sh` (no page download):

```
iteration,warmup,latency_ms,bytes_read,bytes_written,group,signature,success
```

| Column | Example | Meaning |
|--------|---------|---------|
| `iteration` | `1` … `35` | Run number (includes warmup runs) |
| `warmup` | `0` or `1` | `1` = discarded from summary (first 5 by default). `0` = counted |
| `latency_ms` | `10.733` | Full `openssl s_client` handshake duration |
| `bytes_read` | `10240` | Handshake bytes read by client |
| `bytes_written` | `1412` | Handshake bytes sent by client |
| `group` | `MLKEM768` | Negotiated KEM |
| `signature` | `mldsa65` | Server signature type |
| `success` | `1` or `0` | `1` if pure ML-KEM + ML-DSA negotiated |

Use this file for assignment proof (handshake uses PQC, handshake size). Use `results.csv` for the classical vs PQC comparison.

### Customize (edit `experiment/config.env`)

```bash
PAGE_SIZE_KB=150
ITERATIONS=60
SIM_LATENCY_MS=50
PORT=7443
```

Do **not** change these values differently per arm — that would invalidate the comparison.

---

## PQC-only lab (handshake benchmarks)

For testing pure PQC TLS without the classical baseline:

```bash
bash pqc/pqc.sh all        # setup + serve + validate + bench
bash pqc/pqc.sh stop       # stop server when done
```

### PQC commands

| Command | Description |
|---------|-------------|
| `check` | Verify OpenSSL has ML-KEM / ML-DSA |
| `setup` | Generate ML-DSA certificates |
| `serve` | Start PQC-only TLS server (port 7443) |
| `validate` | Confirm handshake uses MLKEM768 + mldsa65 |
| `bench` | Handshake latency benchmark |
| `all` | Full pipeline |

### PQC output

| File | Contents |
|------|----------|
| `pqc/data/validation.txt` | Handshake algorithm proof |
| `pqc/data/pqc-benchmark.csv` | Per-iteration handshake data |
| `pqc/data/pqc-summary.txt` | Aggregated handshake stats |

### PQC environment variables

```bash
PORT=7443
KEM_GROUP=MLKEM768          # pure ML-KEM (not X25519MLKEM768 hybrid)
SIG_ALG=mldsa65
ITERATIONS=30
WARMUP=5
```

---

## Algorithms used

### PQC arm (pure post-quantum)

| Role | OpenSSL name | Standard |
|------|-------------|----------|
| Key exchange | `MLKEM768` | ML-KEM-768 (FIPS 203 / Kyber) |
| Signature | `mldsa65` | ML-DSA-65 (FIPS 204 / Dilithium) |

### Classical arm (baseline)

| Role | OpenSSL name |
|------|-------------|
| Key exchange | `X25519` |
| Signature | `ecdsa_secp256r1_sha256` (ECDSA P-256 cert) |

---

## Experimental design — why we chose this

This section documents the reasoning behind our setup so the comparison stays defensible in a report and reproducible by teammates.

### Research goal

We want to measure **speed and reliability** of TLS when using NIST-standardized post-quantum algorithms vs a modern classical baseline — not to prove production readiness, but to quantify the cost of going full-PQC today.

### Algorithm choices

| Choice | Why |
|--------|-----|
| **ML-KEM-768** (Kyber) | NIST's recommended default security level (FIPS 203). Widely considered the PQC replacement for ECDH key exchange. Level 768 balances security and performance vs 512/1024. |
| **ML-DSA-65** (Dilithium) | NIST default signature scheme (FIPS 204). Level 65 is the middle tier — analogous to picking a mainstream security level rather than the smallest or largest variant. |
| **Pure PQC, not hybrid** (`MLKEM768`, not `X25519MLKEM768`) | Hybrids mix classical + PQC and hide the true PQC overhead. We isolate **full post-quantum cost** so the experiment answers: *what if everything were quantum-safe?* Production will likely use hybrids first; we document that as a limitation. |
| **X25519 + ECDSA P-256** (classical) | Represents what most modern TLS 1.3 sites use today: elliptic-curve key exchange and ECDSA certificates. A fair baseline — not obsolete RSA-2048, not exotic Ed25519-only stacks. |

### Toolchain choices

| Choice | Why |
|--------|-----|
| **OpenSSL 3.5+ (native)** | Ships ML-KEM and ML-DSA in the default provider — same algorithms as liboqs/OQS, without a multi-minute compile of liboqs + oqs-provider. Fewer moving parts = fewer confounders. |
| **`openssl s_server`** | Built-in TLS server; same binary for both arms. No nginx compile, no Docker images, no web server config drift between classical and PQC. |
| **curl** | One measurement tool for both arms. Records connect time, TLS handshake (`appconnect`), total time, and bytes downloaded in a single, scriptable format. Avoids mixing browser DevTools, `s_client`, and curl across arms. |
| **bash + awk + bc** | Minimal dependencies; teammates can run without Python, Node, or extra packages. |

### Controlled conditions (critical for a valid comparison)

These must stay **identical** across classical and PQC. They are locked in `experiment/config.env` and recorded in `manifest.txt`:

| Parameter | Value | Why |
|-----------|-------|-----|
| **Page size** | 150 KB | Large enough that transfer time matters beyond handshake alone, small enough to run 120 trials quickly on localhost. Fixed payload removes "different content" as a variable. |
| **Iterations** | 60 per arm | Enough samples for stable means without an hour-long run. Same count on both sides so statistics are comparable. |
| **Simulated latency** | 50 ms | Pure localhost tests understate real-world network delay. Adding equal delay before each request stops handshake noise from dominating unrealistically. Uses `tc netem` when sudo allows; otherwise the same 50 ms sleep for **both** arms. |
| **Output format** | One CSV schema | Every row has the same columns so aggregation and plotting don't need per-arm parsers. `success=1` only when bytes **and** algorithms match expectations. |
| **TLS version** | 1.3 only | PQC integration targets TLS 1.3. TLS 1.2 would mix in legacy cipher negotiation and muddy results. |
| **Symmetric cipher** | AES-256-GCM (negotiated) | After the handshake, both arms use the same AEAD. Measured differences come from **key exchange and certificates**, not from picking different bulk ciphers. |

### What we measure vs what we don't

**Measured:**
- Total time to fetch the 150 KB page (connect → TLS → download)
- TLS handshake time (`appconnect` in curl)
- Success rate and negotiated algorithms (validated per row)
- Handshake byte counts (in the PQC-only lab via `pqc/pqc.sh`)

**Not measured (out of scope / limitations):**
- Browser UX, HTTP/3, or QUIC
- Hybrid PQC deployments (`X25519MLKEM768`) — common in production but a different experiment
- CPU load, memory, or battery on mobile
- Real WAN latency (unless `tc netem` is enabled with sudo)
- Certificate chain depth, OCSP, or CDN behavior

### Interpreting results fairly

From our runs on this machine (localhost + 50 ms simulated delay):

- **PQC was ~30–40% slower on mean total time**, driven mainly by handshake (larger ML-DSA certs + ML-KEM negotiation).
- **Reliability was 100%** for both arms in controlled runs.
- **Download size was identical** (153,600 bytes) — overhead is in TLS setup, not the page body.

When writing up conclusions, tie numbers back to `experiment/data/manifest.txt` and `results.csv` so reviewers can verify both arms used the same page, tool, latency setting, and trial count.

---

## Simulated latency

The experiment adds **50 ms** of latency before each request so both arms see the same delay.

1. **Preferred:** Linux `tc netem` on loopback (kernel-level):
   ```bash
   sudo tc qdisc replace dev lo root netem delay 50ms
   ```
   Requires passwordless sudo. The script tries this automatically.

2. **Fallback:** 50 ms `sleep` before each curl request (used when `sudo` is unavailable). Both arms still get identical treatment.

To force kernel-level latency, configure sudo for `tc` and re-run:
```bash
bash experiment/run.sh run
```
Check `experiment/data/manifest.txt` — `latency_method` will show `tc-netem` or `client-sleep`.

---

## Troubleshooting

### `Need OpenSSL >= 3.5`

ML-KEM and ML-DSA require OpenSSL 3.5+. Upgrade OpenSSL or use a system that ships 3.5+ (Ubuntu 25.04+, etc.).

### `Cannot open openssl-oqs.cnf`

Unset stale environment from a previous liboqs session:
```bash
unset OPENSSL_CONF OPENSSL_MODULES LD_LIBRARY_PATH
```

### Port already in use

```bash
bash pqc/pqc.sh stop
# or
kill "$(cat experiment/data/server.pid)" 2>/dev/null
```

### Classical rows show `success=0`

Re-run the experiment — an older bug with group parsing has been fixed. Verify with:
```bash
awk -F, 'NR>1 {print $2, $12}' experiment/data/results.csv | sort | uniq -c
# expect: 60 classical 1  and  60 pqc 1
```

---

## Notes for the team

1. **Use `experiment/run.sh` for the final comparison** — see [Experimental design](#experimental-design--why-we-chose-this) for rationale.
2. **Share `experiment/data/manifest.txt`** with your report as proof that both arms ran under identical conditions.
3. **Cite limitations** — pure PQC vs hybrid, localhost vs real network — when drawing conclusions.
