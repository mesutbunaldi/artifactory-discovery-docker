#!/bin/bash
# run.sh - Discovery v4'ü çalıştır

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="discovery-v4:latest"
ENV_FILE="${SCRIPT_DIR}/discovery.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "❌ HATA: discovery.env bulunamadı."
  echo "   discovery.env.example'ı kopyala ve doldur:"
  echo "   cp discovery.env.example discovery.env"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "❌ HATA: Docker bulunamadı."
  echo "   Docker Desktop'ı yükle: https://www.docker.com/products/docker-desktop/"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "❌ HATA: Docker daemon çalışmıyor."
  exit 1
fi

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo "🔨 Docker image build ediliyor..."
  docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"
  echo ""
fi

mkdir -p "${SCRIPT_DIR}/output"

echo "🚀 Container başlatılıyor..."
echo ""

docker run --rm \
  --env-file "${ENV_FILE}" \
  -v "${SCRIPT_DIR}/output:/app/output" \
  "${IMAGE_NAME}"

echo ""
echo "📁 Sonuçlar: ${SCRIPT_DIR}/output/"
echo "📊 Excel:    ${SCRIPT_DIR}/output/discovery-report.xlsx"
