# Practice 5 — Data Collection and Analysis
Uziel Almonte and William Lang

---

## 5. Applying the instrument to the sample

### 5.1 Applied instrument

An **automated measurement instrument** developed for this study (`experiment/run.sh`) was applied, ensuring identical conditions between experimental arms:

| Control | Applied value |
|---------|----------------|
| Web page | 150 KB (`page-150k.bin`, 153,600 bytes) |
| Measurement tool | **curl 8.18** (OpenSSL 3.5.5) |
| Iterations per group | **60** |
| Simulated latency | **50 ms** before each request |
| Protocol | TLS 1.3 |
| Port | 7443 |
| Server | `openssl s_server` |

**Cryptographic validation:** `openssl s_client` verified the TLS group and negotiated signature algorithm in each iteration.

> **Methodological note:** Practice II mentioned JMeter, Wireshark, and Prometheus. For this pilot phase, a unified script (curl + OpenSSL) was used to directly measure dependent variables (`total_ms`, `appconnect_ms`) with lower overhead and reproducibility in a controlled environment. Wireshark/JMeter can be incorporated in a cross-validation phase.

### 5.2 Experimental setup (compared arms)

The hypothesis compares **traditional cryptography** versus **post-quantum cryptography in TLS**. In practice, TLS combines a key exchange algorithm and a signature algorithm in each connection. Therefore, **two arms** were defined (not four isolated groups):

| Arm | Key exchange | Signature (certificate) | NIST equivalent |
|-------|----------------------|---------------------|------------------|
| **Classical** | X25519 | ECDSA P-256 | Modern TLS 1.3 baseline |
| **Post-quantum** | ML-KEM-768 (Kyber) | ML-DSA-65 (Dilithium) | NIST PQC |

> RSA-2048 was not included in TLS 1.3 because it is not the typical key exchange in modern sites (ECDH/X25519 is used). ECDSA P-256 does represent the current certificate standard.

### 5.3 Collected sample

- **Population:** page load and handshake time measurements under controlled conditions.
- **Sampling:** 60 independent runs per arm (**n = 120** total).
- **Valid data:** 120/120 (`success = 1` in all rows).
- **File:** `experiment/data/results.csv`
- **Manifest:** `experiment/data/manifest.txt`

---

## 6. Quantitative analysis methods

### 6.1 Variable types

| Variable | Type | Scale | Analysis |
|----------|------|--------|----------|
| Algorithm type (`mode`) | Independent | Nominal (classical / pqc) | Grouping factor |
| Total time (`total_ms`) | Dependent | Ratio (ms) | Inferential statistics |
| TLS handshake (`appconnect_ms`) | Dependent | Ratio (ms) | Inferential statistics |

### 6.2 Descriptive statistics

For each arm, **n, mean, standard deviation, median, minimum, and maximum** were calculated.

### 6.3 Inferential statistics

Since **two independent groups** with a continuous variable are compared:

1. **Normality test:** Shapiro-Wilk per group.
2. **Independent samples Student's t-test (Welch):** does not assume equal variances.
3. **Mann-Whitney U test:** non-parametric alternative (reinforcement, given normality rejection).
4. **Effect size:** Cohen's *d*.
5. **Significance level:** α = 0.05.

> Although Shapiro-Wilk rejected normality (common in latencies), with **n = 60** the CLT supports using the t-test on means; Mann-Whitney confirms the result without assuming normality.

**Analysis script:** `analysis/analyze.R`  
**Charts:** `analysis/output/*.png`

---

## 7. Results

### 7.1 Descriptive statistics

**Table 1. Total page load time (150 KB)**

| Arm | n | Mean (ms) | SD (ms) | Median (ms) | Min (ms) | Max (ms) |
|-------|---|------------|---------|--------------|----------|----------|
| Classical (X25519 + ECDSA) | 60 | **3.63** | 1.21 | 3.27 | 2.82 | 8.38 |
| Post-quantum (ML-KEM + ML-DSA) | 60 | **4.93** | 1.49 | 4.43 | 3.47 | 9.99 |

**Table 2. TLS handshake duration (`appconnect`)**

| Arm | n | Mean (ms) | SD (ms) | Median (ms) | Min (ms) | Max (ms) |
|-------|---|------------|---------|--------------|----------|----------|
| Classical | 60 | **3.16** | 1.05 | 2.86 | 2.48 | 7.61 |
| Post-quantum | 60 | **4.45** | 1.41 | 3.89 | 3.13 | 9.37 |

**Observation:** The post-quantum arm is consistently slower. The difference is concentrated in the handshake; TCP time (`connect_ms`) is similar (~0.15 ms in both).

### 7.2 Hypothesis test

**Null hypothesis (H₀):** There is no difference in load time between classical and post-quantum algorithms.  
**Alternative hypothesis (H₁):** There is a statistically significant difference.

**Table 3. Welch t-test (α = 0.05)**

| Variable | Classical (ms) | PQC (ms) | Difference | % | t | df | p-value | Cohen's d | 95% CI diff |
|----------|-------------|----------|------------|---|-----|-----|---------|-----------|-------------|
| Total time | 3.63 | 4.93 | +1.30 | +35.9% | -5.26 | 113.4 | **< 0.001** | 0.96 | [-1.79, -0.81] |
| Handshake | 3.16 | 4.45 | +1.29 | +41.0% | -5.70 | 109.3 | **< 0.001** | 1.04 | [-1.74, -0.84] |

**Mann-Whitney U:** p < 0.001 for both variables (confirms the result).

**Statistical conclusion:** **H₀ is rejected**. The difference in load time and handshake duration is **statistically significant** (p < 0.001) with a **large effect size** (Cohen's d ≈ 1.0).

### 7.3 Charts

| Figure | File | Description |
|--------|---------|-------------|
| Figure 1 | `analysis/output/total_ms_boxplot.png` | Boxplot — total time by arm |
| Figure 2 | `analysis/output/handshake_boxplot.png` | Boxplot — TLS handshake by arm |
| Figure 3 | `analysis/output/total_ms_histogram.png` | Overlaid latency histograms |


---

## 8. Analysis in relation to the research question

**Question:** What is the statistically significant difference in secure website load time when using PQC (Kyber + Dilithium) versus traditional algorithms under controlled network conditions?

### Main findings

1. **Yes, there is a significant difference.** PQC is ~1.3 ms slower in total load and ~1.3 ms in handshake (p < 0.001).

2. **The overhead is proportionally moderate in this environment** (~36% more in total time), but the statistical effect is large (d ≈ 1.0) due to the consistency of the pattern across 60 samples.

3. **Most of the cost is in the handshake**, not in the 150 KB download (same in both arms). This confirms that PQC impact is mainly due to:
   - Larger ML-DSA certificates (~7 KB vs ~1 KB ECDSA).
   - Larger ML-KEM exchange messages than X25519.
   - More expensive lattice-based cryptographic operations.

4. **Reliability:** 100% success in both arms (60/60). PQC did not degrade reliability under controlled conditions.

5. **UX relevance:** In this environment (localhost + simulated 50 ms), the absolute difference (~1.3 ms) is **well below** the 100 ms threshold cited in the proposal. In real networks with higher latency, the fixed handshake component would weigh more in relative terms.

### Direct response to the hypothesis

> Under controlled conditions (150 KB page, TLS 1.3, 60 measurements per arm, simulated 50 ms latency), **the use of CRYSTALS-Kyber (ML-KEM-768) and CRYSTALS-Dilithium (ML-DSA-65) produces significantly higher load time and TLS handshake time** than the classical X25519 + ECDSA P-256 configuration (p < 0.001). The hypothesis of a significant difference **is accepted**.

### Limitations of this phase

| Aspect | Practice II (design) | Current implementation |
|---------|---------------------|------------------------|
| Groups | 4 separate levels | 2 TLS arms (combined KEM+signature) |
| RSA-2048 | Included | No (TLS 1.3 uses ECDH/X25519) |
| Latency | 20 ms ± 2 ms, 100 Mbps | 50 ms sleep (`tc netem` pending) |
| Hardware | Dedicated Xeon E-2288G | WSL2 / local environment |
| Tools | JMeter + Wireshark | curl + OpenSSL (custom script) |

These limitations do not invalidate the significance finding, but they **must be reported** and addressed in future iterations (dedicated server, `tc netem`, cross-validation with Wireshark).

---

## 9. How to reproduce

```bash
# Collect data
bash experiment/run.sh all

# Statistical analysis + charts
Rscript analysis/analyze.R
```

---

## Suggested references for the report

- NIST FIPS 203 (ML-KEM) and FIPS 204 (ML-DSA).
- Shor, P. — quantum algorithm for factoring/discrete log.
- OpenSSL 3.5 release notes — native PQC support.
