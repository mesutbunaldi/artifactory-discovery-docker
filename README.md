# Artifactory Discovery (Docker)

100+ repolu Artifactory ortamını tarayıp:
- Hangi servisler publish ediyor
- Hangi teknolojilerle (Maven, NuGet, npm, Docker, Helm, ...)
- Hangi CI tool'larıyla (Jenkins, GitLab CI, ...)
- Hangi VCS repodan (Bitbucket / GitLab) geliyor

→ Excel raporu olarak çıkartır.

## Mac'te Hızlı Başlangıç

### 1. Docker Desktop'ı Yükle

Mac App Store'dan değil, resmi siteden:
https://www.docker.com/products/docker-desktop/

Yükledikten sonra Docker Desktop'ı başlat (ilk açılışta birkaç dakika alabilir).

### 2. Bu klasördeki dosyaları aç

Bu klasörde 4 dosya olmalı:
- `Dockerfile`
- `artifactory-discovery.sh`
- `artifactory-discovery.env`  ← **sadece bunu düzenleyeceksin**
- `run.sh`

### 3. Env dosyasını düzenle

Terminal'de:
```bash
cd ~/Downloads/artifactory-discovery   # dosyaların olduğu yer
nano artifactory-discovery.env         # veya: open -e artifactory-discovery.env
```

Doldur:
```
ARTIFACTORY_URL="https://artifactory.sirket.com/artifactory"
ARTIFACTORY_USER="senin-kullanici-adın"
ARTIFACTORY_TOKEN="api-token-veya-sifre"
```

API token nasıl alınır:
- Artifactory web UI'a gir → sağ üst → profil ikonu
- "Generate API Key" veya "Generate Identity Token"
- Çıkan değeri kopyala, `ARTIFACTORY_TOKEN` alanına yapıştır

### 4. Çalıştır

```bash
chmod +x run.sh
./run.sh
```

İlk çalıştırmada Docker image build edilecek (3-5 dakika). Sonraki çalıştırmalarda doğrudan başlayacak.

### 5. Çıktıyı al

```bash
open output/artifactory-discovery-report.xlsx
```

## Çıktı: Excel Raporu (5 Sheet)

| Sheet | İçerik |
|---|---|
| 1. Publish Eden Servisler | Ana liste — vcs_url, dil, build_tool, ci_tool, artifactory_repo |
| 2. Artifactory Repo Özeti | Hangi repoda kaç artifact, son publish ne zaman |
| 3. Teknoloji Dağılımı | Java: X, .NET: Y, Node: Z |
| 4. Yeni Repo Önerileri | Yeni Artifactory için repo listesi |
| 5. Aktif Olmayan Repolar | Son N gündür publish yok (cleanup adayları) |

## İleri Kullanım

### Tarihi değiştirmek (kaç gün geriye?)

`artifactory-discovery.env` dosyasında:
```
DAYS_BACK=365   # 1 yıl
```

### Image'ı yeniden build etmek

Script güncellenirse:
```bash
docker rmi artifactory-discovery:latest
./run.sh   # otomatik tekrar build edecek
```

### Manuel docker run (run.sh kullanmadan)

```bash
docker build -t artifactory-discovery .
docker run --rm \
  -v "$(pwd)/artifactory-discovery.env:/app/config/artifactory-discovery.env:ro" \
  -v "$(pwd)/output:/app/output" \
  artifactory-discovery
```

## Sorun Giderme

**"Cannot connect to Docker daemon"** → Docker Desktop başlatılmamış. Sağ üstteki balina ikonu yeşil olmalı.

**"401 Unauthorized" veya "403 Forbidden"** → Token yanlış veya süresi dolmuş. Yeni bir API token oluştur.

**AQL "permission denied"** → Kullanıcının "Repositories Read" + "Builds Read" yetkisi olmalı. Artifactory admin'e sor.

**"This site can't be reached" (curl errors)** → Artifactory URL yanlış veya VPN'de değilsin. URL'in doğru olduğundan emin ol (sondaki `/artifactory` dahil).

**Excel boş geliyor** → Artifactory'de son N gün içinde publish yok demektir. `DAYS_BACK=365` yap, 1 yıla genişlet.

## Mantık

Repo bazlı tarama yerine **Artifactory'den geriye doğru** çalışıyoruz:

```
Artifactory'deki gerçek artifact'ler  →  build-info metadata  →  VCS URL
       (gerçeğin tek kaynağı)              (kim/ne yayınladı)      (kaynak repo)
```

Bu sadece **gerçekten sürüm çıkan** servisleri yakalar — "yazılmış ama publish etmemiş" repolarda zaman kaybetmezsin.
