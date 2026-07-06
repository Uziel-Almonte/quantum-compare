#!/usr/bin/env Rscript
# Statistical analysis for quantum-compare experiment (Practice 5)
csv <- commandArgs(trailingOnly = TRUE)
if (length(csv) == 0) csv <- "experiment/data/results.csv"
out_dir <- "analysis/output"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

df <- read.csv(csv, stringsAsFactors = FALSE)
df <- df[df$success == 1, ]
df$mode <- factor(df$mode, levels = c("classical", "pqc"))

cat("=== Descriptive statistics ===\n")
for (var in c("total_ms", "appconnect_ms", "connect_ms")) {
  cat("\n--", var, "--\n")
  print(aggregate(as.formula(paste(var, "~ mode")), data = df,
                  FUN = function(x) c(n = length(x), mean = mean(x), sd = sd(x),
                                      median = median(x), min = min(x), max = max(x))))
}

cat("\n=== Welch t-test (classical vs pqc) ===\n")
for (var in c("total_ms", "appconnect_ms")) {
  cl <- df[df$mode == "classical", var]
  pq <- df[df$mode == "pqc", var]
  tt <- t.test(cl, pq, var.equal = FALSE)
  d <- (mean(pq) - mean(cl)) / sqrt((var(cl) + var(pq)) / 2)
  cat(sprintf("\n%s:\n", var))
  cat(sprintf("  classical mean = %.3f ms (sd=%.3f)\n", mean(cl), sd(cl)))
  cat(sprintf("  pqc       mean = %.3f ms (sd=%.3f)\n", mean(pq), sd(pq)))
  cat(sprintf("  difference    = %.3f ms (%.1f%%)\n", mean(pq) - mean(cl),
              100 * (mean(pq) - mean(cl)) / mean(cl)))
  cat(sprintf("  t(%.1f) = %.4f, p-value = %.6f\n", tt$parameter, tt$statistic, tt$p.value))
  cat(sprintf("  Cohen d       = %.3f\n", d))
  cat(sprintf("  95%% CI diff   = [%.3f, %.3f]\n", tt$conf.int[1], tt$conf.int[2]))
}

cat("\n=== Mann-Whitney U (non-parametric) ===\n")
for (var in c("total_ms", "appconnect_ms")) {
  wt <- wilcox.test(df[[var]] ~ df$mode)
  cat(sprintf("%s: W = %.0f, p-value = %.6f\n", var, wt$statistic, wt$p.value))
}

cat("\n=== Normality (Shapiro-Wilk per group) ===\n")
for (var in c("total_ms", "appconnect_ms")) {
  for (m in levels(df$mode)) {
    x <- df[df$mode == m, var]
    sw <- shapiro.test(x)
    cat(sprintf("%s %s: W=%.4f p=%.4f\n", m, var, sw$statistic, sw$p.value))
  }
}

# Plots
png(file.path(out_dir, "total_ms_boxplot.png"), width = 800, height = 500, res = 120)
boxplot(total_ms ~ mode, data = df,
        main = "Tiempo total de carga (150 KB)",
        xlab = "Algoritmo", ylab = "ms",
        names = c("Clásico\n(X25519+ECDSA)", "Post-cuántico\n(ML-KEM+ML-DSA)"),
        col = c("#4CAF50", "#2196F3"))
dev.off()

png(file.path(out_dir, "handshake_boxplot.png"), width = 800, height = 500, res = 120)
boxplot(appconnect_ms ~ mode, data = df,
        main = "Duración del handshake TLS",
        xlab = "Algoritmo", ylab = "ms",
        names = c("Clásico\n(X25519+ECDSA)", "Post-cuántico\n(ML-KEM+ML-DSA)"),
        col = c("#4CAF50", "#2196F3"))
dev.off()

png(file.path(out_dir, "total_ms_histogram.png"), width = 900, height = 500, res = 120)
hist(df$total_ms[df$mode == "classical"], breaks = 15, col = rgb(0.3,0.7,0.3,0.5),
     main = "Distribución del tiempo total", xlab = "ms", xlim = range(df$total_ms))
hist(df$total_ms[df$mode == "pqc"], breaks = 15, col = rgb(0.2,0.5,0.9,0.5), add = TRUE)
legend("topright", c("Clásico", "Post-cuántico"), fill = c(rgb(0.3,0.7,0.3,0.5), rgb(0.2,0.5,0.9,0.5)))
dev.off()

write.csv(df, file.path(out_dir, "clean_data.csv"), row.names = FALSE)
cat("\nPlots saved to", out_dir, "\n")
