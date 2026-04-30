FROM benim.repom.com:5001/artifactory/python:3.12-slim

# Sistem bağımlılıkları (curl, jq, git)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        jq \
        git \
        ca-certificates \
        tzdata && \
    rm -rf /var/lib/apt/lists/*

# Python bağımlılıkları
RUN pip install --no-cache-dir \
    pandas==2.2.3 \
    openpyxl==3.1.5

WORKDIR /app

# Modüller
COPY discovery.py /app/discovery.py
COPY ansible_scanner.py /app/ansible_scanner.py
COPY jenkins_scanner.py /app/jenkins_scanner.py
COPY repo_scanner.py /app/repo_scanner.py
COPY correlator.py /app/correlator.py

RUN chmod +x /app/discovery.py
RUN mkdir -p /app/output
ENTRYPOINT ["/bin/bash", "-c", "set -a && source /app/discovery.env && python3 /app/discovery.py"]
