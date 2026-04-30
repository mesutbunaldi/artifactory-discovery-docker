FROM benim.repom.com:5001/artifactory/python:3.12-slim

# Sistem bağımlılıkları (curl ve jq)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        jq \
        ca-certificates \
        tzdata && \
    rm -rf /var/lib/apt/lists/*

# Python bağımlılıkları
RUN pip install --no-cache-dir \
    pandas==2.2.3 \
    openpyxl==3.1.5

# Çalışma klasörü
WORKDIR /app

# Script'i kopyala
COPY artifactory-discovery.sh /app/artifactory-discovery.sh
RUN chmod +x /app/artifactory-discovery.sh

# Output klasörünü hazırla (volume mount edilecek)
RUN mkdir -p /app/output

# Default komut
ENTRYPOINT ["/app/artifactory-discovery.sh"]
