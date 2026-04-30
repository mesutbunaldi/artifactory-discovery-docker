# Discovery v4 — 4 Kaynak Cross-Reference

> **Yenilik (v4):** Servis reposu manifest analizi eklendi. `pom.xml`, `package.json`, vs. dosyalarından **kesin** build tool tespiti.

## Veri Kaynakları (Öncelik Sırası)

```
🥇 1. Servis Reposu Manifestleri         (EN GÜÇLÜ — pom.xml, package.json, *.csproj, ...)
🥈 2. Servis Reposundaki Jenkinsfile     (Ekiplerin kendi yazdığı pipeline)
🥉 3. Ansible Roles                      (Build komutları regex'i)
   4. Jenkins Console Log                (Gerçek çalışan komutlar)
   5. Jenkins config.xml                 (Inline pipeline / shell)
```

## Confidence Yorumlama

| Renk | Confidence | Anlamı |
|---|---|---|
| 🟢 | **high** | Manifest + en az 1 CI kaynağı uzlaşıyor |
| 🟡 | **medium** | Manifest var ama hiç build edilmiyor / Sadece CI kaynakları uzlaşıyor |
| 🟠 | **conflict** | Manifest var **ama CI farklı şey diyor!** ⚠️ İncele |
| 🔴 | **low** | Tek CI kaynağından tespit (zayıf kanıt) |
| ⚫ | **no-data** | Hiçbir kaynaktan veri yok |

**Conflict** kategorisi en değerli — orada gerçek bir problem var:
- Repo'da `pom.xml` var ama Jenkins'te `npm publish` çalışıyor
- Yanlış Jenkins job bağlantısı
- Multi-language repo (legacy artifact'ler kalmış)

## Pipeline

```
[1] ansible-roles (Bitbucket) klonla → role bazında build tool çıkar
[2] Jenkins API → tüm job'lar (folder/multibranch dahil)
[3] Servis repolarını API ile tara (manifest + Jenkinsfile)
        - Bitbucket Server: /rest/api/1.0/projects/.../raw/...
        - GitLab: /api/v4/projects/.../repository/files/.../raw
[4] (opsiyonel) Artifactory cross-ref
[5] Cross-reference + Excel (8 sheet)
```

## Mac'te Hızlı Başlangıç

### 1. Docker Desktop
https://www.docker.com/products/docker-desktop/

### 2. Env'i doldur

```bash
cp discovery.env.example discovery.env
nano discovery.env
```

Gereken token'lar:

| Token | Nereden | Permission |
|---|---|---|
| `BITBUCKET_TOKEN` | Profile → HTTP access tokens | Repositories Read |
| `GITLAB_TOKEN` | User Settings → Access Tokens | `read_api` + `read_repository` |
| `JENKINS_TOKEN` | User → Configure → API Token | (otomatik) |

### 3. Çalıştır

```bash
chmod +x run.sh
./run.sh
```

## Excel Raporu (8 Sheet)

| # | Sheet | İçerik |
|---|---|---|
| 1 | **Cross-Reference (Ana)** | Final liste — manifest + Jenkinsfile + role + config + log birleşik |
| 2 | Confidence Dağılımı | Kaç tane high/medium/conflict/low |
| 3 | **İncelenecek (Conflict)** | 🟠 manifest≠CI olanlar — manuel review |
| 4 | Servis Repo Analizi | Her repoda hangi manifest dosyaları var, metadata (groupId, artifactId, ...) |
| 5 | Ansible Roles | Her rol hangi build tool kullanıyor |
| 6 | Teknoloji Dağılımı | Java: X, .NET: Y, Node: Z |
| 7 | Yeni Repo Önerileri | Yeni Artifactory için repo listesi |
| 8 | Ham Jenkins Jobs | Debug için tam liste |

## Performans

100 servis için tahmini süreler:

| Adım | `FETCH_BUILD_LOGS=false` | `FETCH_BUILD_LOGS=true` |
|---|---|---|
| ansible-roles klonlama | 5-30 sn | 5-30 sn |
| Jenkins job tarama | 1-2 dk | 3-5 dk |
| Servis repo tarama | 1-2 dk | 1-2 dk |
| **Toplam** | **~3 dk** | **~7 dk** |

İlk testte `FETCH_BUILD_LOGS=false` ile başla. Sheet 1'de `confidence=low` çoksa true yap.

## Hızlı Test (servis repo taraması olmadan)

Sadece v3 davranışı için:
```
SKIP_REPO_SCAN=true
```

## Manifest Tarama Detayı

Her servis reposundan şu dosyalar denenir:

| Dosya | Tespit Edilen |
|---|---|
| `pom.xml` | Java/Maven (bonus: groupId, artifactId, multi-module) |
| `build.gradle` / `*.kts` | Java/Gradle |
| `package.json` | Node.js (bonus: name, has_publish_script) |
| `*.csproj` / `*.sln` | .NET |
| `requirements.txt` / `pyproject.toml` / `setup.py` | Python |
| `go.mod` | Go (bonus: module path) |
| `Cargo.toml` | Rust |
| `composer.json` | PHP |
| `Gemfile` | Ruby |
| `Dockerfile` | Container |
| `Chart.yaml` | Helm |
| `Jenkinsfile` | (Pipeline analizi) |

## Debug

### Container'a exec at
```bash
docker run --rm -it \
  --env-file discovery.env \
  -v "$(pwd)/output:/app/output" \
  --entrypoint /bin/bash \
  discovery-v4:latest

cd /app
python3 -c "
import repo_scanner
r = repo_scanner.scan_repo(
    'https://bitbucket.sirket.com/scm/proj/repo',
    'main',
    bb_user='\$BITBUCKET_USER',
    bb_token='\$BITBUCKET_TOKEN',
    gl_token=''
)
print(r)
"
```

### Ara dosyalar
- `output/01-ansible-roles.json`
- `output/02-jenkins-jobs.json`
- `output/03-service-repos.json`  ⭐ Yeni
- `output/discovery-report.xlsx`

## Internal Artifactory'den Base Image

```dockerfile
FROM artifactory.sirket.com:5001/docker-remote/python:3.12-slim
```

`docker login artifactory.sirket.com:5001` ile auth ol.

## Self-Signed Sertifika / Internal CA

Kurumsal ortamda Bitbucket/Jenkins/GitLab self-signed veya internal CA imzalı sertifika kullanıyorsa env'e ekle:

```
VERIFY_SSL=false
```

Bu ayar:
- ✅ Python `urllib` çağrılarını (Jenkins API + Bitbucket/GitLab API) etkiler
- ✅ `git clone` çağrılarını da etkiler (`GIT_SSL_NO_VERIFY=true` set eder)
- ✅ `urllib3` InsecureRequestWarning uyarılarını susturur

⚠️ Sadece güvenli internal ortamda kullan — production'da `VERIFY_SSL=true` (varsayılan) tut.

## Lisans

MIT
