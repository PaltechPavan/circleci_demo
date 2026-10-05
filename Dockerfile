FROM python:3.11-slim

WORKDIR /app

# ============================================================
# Install system dependencies
# ============================================================

RUN apt-get update && \
    apt-get install -y \
        git \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# ============================================================
# Install AWS CLI v2
# ============================================================

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o "/tmp/awscliv2.zip" && \
    unzip /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

# ============================================================
# Install Python/dbt dependencies
# ============================================================

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

# ============================================================
# Verify installations
# ============================================================

RUN python --version
RUN dbt --version
RUN aws --version

# ============================================================
# Copy dbt project
# ============================================================

COPY . .

# ============================================================
# Make entrypoint executable
# ============================================================

RUN chmod +x entrypoint.sh

# ============================================================
# dbt configuration
# ============================================================

ENV DBT_PROFILES_DIR=/app

# ============================================================
# Container startup
# ============================================================

ENTRYPOINT ["./entrypoint.sh"]