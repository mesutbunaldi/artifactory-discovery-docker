#!/bin/bash
# run.sh - Docker container'ı başlat
# Mac kullanıcısı sadece bunu çalıştırır:
#   chmod +x run.sh
#   ./run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="artifactory-discovery:latest"
ENV_FILE="${SCRIPT_DIR}/artifactory-discovery.env"

# Env dosyası kontrolü
if [ ! -f "${ENV_FILE}" ]; then
  echo "❌ HATA: artifactory-discovery.env bulunamadı."
  echo "   Bu klasörde olmalı: ${SCRIPT_DIR}"
  exit 1
fi

# Docker var mı?
if ! command -v docker >/dev/null 2>&1; then
  echo "❌ HATA: Docker bulunamadı."
  echo "   Docker Desktop'ı yükle: https://www.docker.com/products/docker-desktop/"
  exit 1
fi

# Docker daemon çalışıyor mu?
if ! docker info >/dev/null 2>&1; then
  echo "❌ HATA: Docker daemon çalışmıyor."
  echo "   Docker Desktop'ı başlat ve tekrar dene."
  exit 1
fi

# Image var mı? Yoksa build et
if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo "🔨 Docker image bulunamadı, build ediliyor..."
  docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"
  echo ""
fi

# Output klasörünü hazırla
mkdir -p "${SCRIPT_DIR}/output"

# Container'ı çalıştır
echo "🚀 Container başlatılıyor..."
echo ""

docker run --rm \
  -v "${ENV_FILE}:/app/config/artifactory-discovery.env:ro" \
  -v "${SCRIPT_DIR}/output:/app/output" \
  "${IMAGE_NAME}"

echo ""
echo "📁 Sonuçlar: ${SCRIPT_DIR}/output/"
echo "📊 Excel: ${SCRIPT_DIR}/output/artifactory-discovery-report.xlsx"
