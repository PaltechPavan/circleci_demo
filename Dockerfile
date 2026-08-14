FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && \
    apt-get install -y git && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

RUN dbt --version

COPY . .

RUN chmod +x entrypoint.sh

ENV DBT_PROFILES_DIR=/app

ENTRYPOINT ["./entrypoint.sh"]