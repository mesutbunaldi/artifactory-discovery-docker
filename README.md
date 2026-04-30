# Artifactory Discovery (Docker) — v2

Generic repolar dahil tüm artifact'lerden teknoloji tespiti yapar.

## Yenilikler (v2)

- 🎯 **Generic repo desteği** — `.jar`, `.nupkg`, `.whl`, `.tgz` gibi dosyaları uzantı + path pattern + (opsiyonel) içerik analiziyle tanır
- 📋 **Yeni sheet'ler**: Generic Repo Breakdown + Belirsiz Artifact Listesi
- 🔬 **Deep Inspect modu** — belirsiz arşivlerin içine bakıp manifest dosyalarından (META-INF/MANIFEST.MF, package.json, Chart.yaml) teknolojiyi tespit eder

## Mac'te Hızlı Başlangıç

### 1. Docker Desktop'ı yükle
https://www.docker.com/products/docker-desktop/

### 2. 4 dosyayı aynı klasöre koy
- `Dockerfile`
- `artifactory-discovery.sh`
- `artifactory-discovery.env`
- `run.sh`

### 3. Env'i doldur
```bash
nano artifactory-discovery.env
```
- `ARTIFACTORY_URL`, `ARTIFACTORY_USER`, `ARTIFACTORY_TOKEN` zorunlu
- `DEEP_INSPECT=true` yaparsan generic repolardaki şüpheli dosyaların içine de bakar (yavaş ama kesin)

### 4. Çalıştır
```bash
chmod +x run.sh
./run.sh
```

## Çıktı: 7 Sheet'lik Excel

| # | Sheet | İçerik |
|---|---|---|
| 1 | Publish Eden Servisler | Ana liste — language, build_tool, confidence, detection_source |
| 2 | Generic Repolar | Generic repo'larda hangi tipte ne kadar artifact var |
| 3 | Artifactory Repo Özeti | Hangi repoda kaç artifact, primary_language |
| 4 | Teknoloji Dağılımı | Java: X, .NET: Y, Node: Z |
| 5 | Yeni Repo Önerileri | Yeni Artifactory için repo listesi |
| 6 | Aktif Olmayan Repolar | Cleanup adayları |
| 7 | Belirsiz Artifact'ler | Tespit edilemeyenler (manuel inceleme listesi) |

## Confidence Seviyeleri (Sheet 1)

| Confidence | Anlamı |
|---|---|
| `high` | Native package type veya kesin uzantı (.jar, .nupkg) — güvenilebilir |
| `medium` | Path pattern veya ambigu uzantı (.dll, manifest.json) — büyük ihtimalle doğru |
| `low` | Sadece dosya adından tahmin (weird.tar.gz) — DEEP_INSPECT ile doğrula |
| `none` | Hiç tespit edilemedi (mystery.bin) — manuel incele |

## Detection Source (nasıl tespit edildi)

| Source | Ne demek |
|---|---|
| `package-type` | Artifactory native package type (Maven/NuGet/npm/...) — en güvenilir |
| `extension` | Dosya uzantısından (.jar, .nupkg, ...) |
| `path-pattern` | Path desen eşleşmesi (Maven layout, Helm chart, ...) |
| `filename+path` | Dosya adı + path kombinasyonu (npm `/-/`, Helm `chart`) |
| `content-jar` | JAR içine bakılıp META-INF/MANIFEST.MF bulundu (DEEP_INSPECT) |
| `content-chart` | tgz içinde Chart.yaml bulundu (DEEP_INSPECT) |
| `build-info` | Sadece Artifactory build-info kaydından geldi |
| `no-match` | Hiçbir kural eşleşmedi → manuel incele |

## Debug için container'a exec atmak

```bash
# ENTRYPOINT'i bypass edip içine gir
docker run --rm -it \
  -v "$(pwd)/artifactory-discovery.env:/app/config/artifactory-discovery.env:ro" \
  -v "$(pwd)/output:/app/output" \
  --entrypoint /bin/bash \
  artifactory-discovery:latest

# İçeride manuel test
source /app/config/artifactory-discovery.env
curl -v -u "$ARTIFACTORY_USER:$ARTIFACTORY_TOKEN" \
  "$ARTIFACTORY_URL/api/repositories?type=local"

# Script'i debug modda çalıştır
bash -x /app/artifactory-discovery.sh
```
