# Práctica 5 — Recolección y análisis de datos
Uziel Almonte and William Lang

---

## 5. Aplicación del instrumento a la muestra

### 5.1 Instrumento aplicado

Se aplicó un **instrumento de medición automatizado** desarrollado para este estudio (`experiment/run.sh`), que garantiza condiciones idénticas entre brazos experimentales:

| Control | Valor aplicado |
|---------|----------------|
| Página web | 150 KB (`page-150k.bin`, 153 600 bytes) |
| Herramienta de medición | **curl 8.18** (OpenSSL 3.5.5) |
| Iteraciones por grupo | **60** |
| Latencia simulada | **50 ms** antes de cada solicitud |
| Protocolo | TLS 1.3 |
| Puerto | 7443 |
| Servidor | `openssl s_server` |

**Validación criptográfica:** `openssl s_client` verificó en cada iteración el grupo TLS y el algoritmo de firma negociados.

> **Nota metodológica:** En la Práctica II se mencionaron JMeter, Wireshark y Prometheus. Para esta fase piloto se utilizó un script unificado (curl + OpenSSL) que mide directamente las variables dependientes (`total_ms`, `appconnect_ms`) con menor overhead y reproducibilidad en entorno controlado. Wireshark/JMeter pueden incorporarse en una fase de validación cruzada.

### 5.2 Configuración experimental (brazos comparados)

La hipótesis compara **criptografía tradicional** frente a **post-cuántica en TLS**. En la práctica, TLS combina un algoritmo de intercambio de claves y uno de firma en cada conexión. Por ello se definieron **dos brazos** (no cuatro grupos aislados):

| Brazo | Intercambio de claves | Firma (certificado) | Equivalente NIST |
|-------|----------------------|---------------------|------------------|
| **Clásico** | X25519 | ECDSA P-256 | Baseline TLS 1.3 moderno |
| **Post-cuántico** | ML-KEM-768 (Kyber) | ML-DSA-65 (Dilithium) | CPQ NIST |

> RSA-2048 no se incluyó en TLS 1.3 porque no es el intercambio de claves típico en sitios modernos (se usa ECDH/X25519). ECDSA P-256 sí representa el estándar actual de certificados.

### 5.3 Muestra recolectada

- **Población:** mediciones de tiempo de carga y handshake bajo condiciones controladas.
- **Muestreo:** 60 ejecuciones independientes por brazo (**n = 120** en total).
- **Datos válidos:** 120/120 (`success = 1` en todas las filas).
- **Archivo:** `experiment/data/results.csv`
- **Manifiesto:** `experiment/data/manifest.txt`

---

## 6. Métodos de análisis cuantitativo

### 6.1 Tipo de variables

| Variable | Tipo | Escala | Análisis |
|----------|------|--------|----------|
| Tipo de algoritmo (`mode`) | Independiente | Nominal (clásico / pqc) | Factor de agrupación |
| Tiempo total (`total_ms`) | Dependiente | Razón (ms) | Estadística inferencial |
| Handshake TLS (`appconnect_ms`) | Dependiente | Razón (ms) | Estadística inferencial |

### 6.2 Estadística descriptiva

Se calcularon para cada brazo: **n, media, desviación estándar, mediana, mínimo y máximo**.

### 6.3 Estadística inferencial

Dado que se comparan **dos grupos independientes** con variable continua:

1. **Prueba de normalidad:** Shapiro-Wilk por grupo.
2. **Prueba t de Student para muestras independientes (Welch):** no asume varianzas iguales.
3. **Prueba de Mann-Whitney U:** alternativa no paramétrica (refuerzo, dado rechazo de normalidad).
4. **Tamaño del efecto:** Cohen's *d*.
5. **Nivel de significancia:** α = 0.05.

> Aunque Shapiro-Wilk rechazó normalidad (común en latencias), con **n = 60** el TCL respalda la prueba t sobre medias; Mann-Whitney confirma el resultado sin asumir normalidad.

**Script de análisis:** `analysis/analyze.R`  
**Gráficos:** `analysis/output/*.png`

---

## 7. Resultados

### 7.1 Estadística descriptiva

**Tabla 1. Tiempo total de carga (150 KB)**

| Brazo | n | Media (ms) | DE (ms) | Mediana (ms) | Mín (ms) | Máx (ms) |
|-------|---|------------|---------|--------------|----------|----------|
| Clásico (X25519 + ECDSA) | 60 | **3.63** | 1.21 | 3.27 | 2.82 | 8.38 |
| Post-cuántico (ML-KEM + ML-DSA) | 60 | **4.93** | 1.49 | 4.43 | 3.47 | 9.99 |

**Tabla 2. Duración del handshake TLS (`appconnect`)**

| Brazo | n | Media (ms) | DE (ms) | Mediana (ms) | Mín (ms) | Máx (ms) |
|-------|---|------------|---------|--------------|----------|----------|
| Clásico | 60 | **3.16** | 1.05 | 2.86 | 2.48 | 7.61 |
| Post-cuántico | 60 | **4.45** | 1.41 | 3.89 | 3.13 | 9.37 |

**Observación:** El brazo post-cuántico es consistentemente más lento. La diferencia se concentra en el handshake; el tiempo TCP (`connect_ms`) es similar (~0.15 ms en ambos).

### 7.2 Prueba de hipótesis

**Hipótesis nula (H₀):** No existe diferencia en el tiempo de carga entre algoritmos clásicos y post-cuánticos.  
**Hipótesis alternativa (H₁):** Existe diferencia estadísticamente significativa.

**Tabla 3. Prueba t de Welch (α = 0.05)**

| Variable | Clásico (ms) | PQC (ms) | Diferencia | % | t | gl | p-valor | Cohen's d | IC 95% diff |
|----------|-------------|----------|------------|---|-----|-----|---------|-----------|-------------|
| Tiempo total | 3.63 | 4.93 | +1.30 | +35.9% | -5.26 | 113.4 | **< 0.001** | 0.96 | [-1.79, -0.81] |
| Handshake | 3.16 | 4.45 | +1.29 | +41.0% | -5.70 | 109.3 | **< 0.001** | 1.04 | [-1.74, -0.84] |

**Mann-Whitney U:** p < 0.001 para ambas variables (confirma el resultado).

**Conclusión estadística:** Se **rechaza H₀**. La diferencia en tiempo de carga y en duración del handshake es **estadísticamente significativa** (p < 0.001) con **tamaño del efecto grande** (Cohen's d ≈ 1.0).

### 7.3 Gráficos

| Figura | Archivo | Descripción |
|--------|---------|-------------|
| Figura 1 | `analysis/output/total_ms_boxplot.png` | Boxplot — tiempo total por brazo |
| Figura 2 | `analysis/output/handshake_boxplot.png` | Boxplot — handshake TLS por brazo |
| Figura 3 | `analysis/output/total_ms_histogram.png` | Histogramas superpuestos de latencia |


---

## 8. Análisis en relación con la pregunta de investigación

**Pregunta:** ¿Cuál es la diferencia estadísticamente significativa en el tiempo de carga de un sitio web seguro al utilizar CPQ (Kyber + Dilithium) frente a algoritmos tradicionales bajo condiciones de red controladas?

### Hallazgos principales

1. **Sí hay diferencia significativa.** CPQ es ~1.3 ms más lento en carga total y ~1.3 ms en handshake (p < 0.001).

2. **El overhead es proporcionalmente moderado en este entorno** (~36% más en tiempo total), pero el efecto estadístico es grande (d ≈ 1.0) por la consistencia del patrón en 60 muestras.

3. **La mayor parte del costo está en el handshake**, no en la descarga de 150 KB (misma en ambos brazos). Esto confirma que el impacto de CPQ se debe principalmente a:
   - Certificados ML-DSA más grandes (~7 KB vs ~1 KB ECDSA).
   - Mensajes de intercambio ML-KEM más grandes que X25519.
   - Operaciones criptográficas de retículos más costosas.

4. **Fiabilidad:** 100% de éxito en ambos brazos (60/60). CPQ no degradó la confiabilidad en condiciones controladas.

5. **Relevancia para UX:** En este entorno (localhost + 50 ms simulados), la diferencia absoluta (~1.3 ms) está **muy por debajo** del umbral de 100 ms citado en el planteamiento. En redes reales con mayor latencia, el componente fijo del handshake pesaría más en términos relativos.

### Respuesta directa a la hipótesis

> Bajo condiciones controladas (página de 150 KB, TLS 1.3, 60 mediciones por brazo, latencia simulada de 50 ms), **el uso de CRYSTALS-Kyber (ML-KEM-768) y CRYSTALS-Dilithium (ML-DSA-65) produce un tiempo de carga y un handshake TLS significativamente mayores** que la configuración clásica X25519 + ECDSA P-256 (p < 0.001). La hipótesis de diferencia significativa **se acepta**.

### Limitaciones de esta fase

| Aspecto | Práctica II (diseño) | Implementación actual |
|---------|---------------------|------------------------|
| Grupos | 4 niveles separados | 2 brazos TLS (KEM+firma combinados) |
| RSA-2048 | Incluido | No (TLS 1.3 usa ECDH/X25519) |
| Latencia | 20 ms ± 2 ms, 100 Mbps | 50 ms sleep (tc netem pendiente) |
| Hardware | Xeon E-2288G dedicado | WSL2 / entorno local |
| Herramientas | JMeter + Wireshark | curl + OpenSSL (script propio) |

Estas limitaciones no invalidan el hallazgo de significancia, pero **deben reportarse** y abordarse en iteraciones futuras (servidor dedicado, `tc netem`, validación cruzada con Wireshark).

---

## 9. Cómo reproducir

```bash
# Recolectar datos
bash experiment/run.sh all

# Análisis estadístico + gráficos
Rscript analysis/analyze.R
```

---

## Referencias sugeridas para el informe

- NIST FIPS 203 (ML-KEM) y FIPS 204 (ML-DSA).
- Shor, P. — algoritmo cuántico para factorización/log discreto.
- OpenSSL 3.5 release notes — soporte nativo PQC.
