# ============================================================
# QA DBT Docker Image
# ============================================================

FROM python:3.11-slim

# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV DBT_PROFILES_DIR=/app

WORKDIR /app

# ------------------------------------------------------------
# System dependencies
# ------------------------------------------------------------

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        unzip \
        ca-certificates \
        jq && \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------
# AWS CLI v2
# ------------------------------------------------------------

RUN curl -fsSL \
        "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

# ------------------------------------------------------------
# Python dependencies
# ------------------------------------------------------------

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

# ------------------------------------------------------------
# Copy dbt project
# ------------------------------------------------------------

COPY . .

# ------------------------------------------------------------
# Copy single-file dbt docs generator
# ------------------------------------------------------------

COPY create_single_dbt_docs.py /app/create_single_dbt_docs.py

# ------------------------------------------------------------
# Create entrypoint
# ------------------------------------------------------------

RUN cat <<'EOF' > /app/entrypoint.sh
#!/bin/bash

set -euo pipefail

echo "=========================================="
echo "QA DBT ECS TASK"
echo "=========================================="

# ============================================================
# Environment variables
# ============================================================

ENVIRONMENT="${ENVIRONMENT:-}"
DBT_STATE_BUCKET="${DBT_STATE_BUCKET:-}"
DBT_RUN_MODE="${DBT_RUN_MODE:-STATE_AWARE}"

# New QA docs bucket
DBT_DOCS_BUCKET="${DBT_DOCS_BUCKET:-}"

echo "Environment:"
echo "${ENVIRONMENT}"

echo "DBT State Bucket:"
echo "${DBT_STATE_BUCKET}"

echo "DBT Run Mode:"
echo "${DBT_RUN_MODE}"

echo "DBT Docs Bucket:"
echo "${DBT_DOCS_BUCKET}"

# ============================================================
# Validate required variables
# ============================================================

if [ -z "${ENVIRONMENT}" ]; then
    echo "ERROR: ENVIRONMENT is not set"
    exit 1
fi

if [ -z "${DBT_STATE_BUCKET}" ]; then
    echo "ERROR: DBT_STATE_BUCKET is not set"
    exit 1
fi

if [ -z "${DBT_DOCS_BUCKET}" ]; then
    echo "ERROR: DBT_DOCS_BUCKET is not set"
    exit 1
fi

if [ "${DBT_RUN_MODE}" != "STATE_AWARE" ] && \
   [ "${DBT_RUN_MODE}" != "FULL" ]; then

    echo "ERROR: DBT_RUN_MODE must be STATE_AWARE or FULL"
    exit 1
fi

# ============================================================
# Paths
# ============================================================

STATE_PATH="s3://${DBT_STATE_BUCKET}/${ENVIRONMENT}/manifest.json"

LOCAL_STATE_DIR="/tmp/dbt-state"
LOCAL_STATE_MANIFEST="${LOCAL_STATE_DIR}/manifest.json"

DOCS_DIR="/app/target"
SINGLE_DOCS_DIR="/app/target/single"
SINGLE_INDEX="${SINGLE_DOCS_DIR}/index.html"

# ============================================================
# Create directories
# ============================================================

mkdir -p "${LOCAL_STATE_DIR}"
mkdir -p "${SINGLE_DOCS_DIR}"

# ============================================================
# Show versions
# ============================================================

echo "=========================================="
echo "Versions"
echo "=========================================="

python --version
dbt --version
aws --version

# ============================================================
# AWS identity
# ============================================================

echo "=========================================="
echo "AWS Identity"
echo "=========================================="

aws sts get-caller-identity

# ============================================================
# dbt deps
# ============================================================

echo "=========================================="
echo "Running dbt deps"
echo "=========================================="

dbt deps

# ============================================================
# dbt debug
# ============================================================

echo "=========================================="
echo "Running dbt debug"
echo "=========================================="

dbt debug

# ============================================================
# STATE AWARE MODE
# ============================================================

if [ "${DBT_RUN_MODE}" = "STATE_AWARE" ]; then

    echo "=========================================="
    echo "STATE AWARE MODE"
    echo "=========================================="

    echo "Checking previous manifest:"
    echo "${STATE_PATH}"

    if aws s3api head-object \
        --bucket "${DBT_STATE_BUCKET}" \
        --key "${ENVIRONMENT}/manifest.json" \
        >/dev/null 2>&1; then

        echo "Previous manifest found."

        echo "Downloading previous manifest..."

        aws s3 cp \
            "${STATE_PATH}" \
            "${LOCAL_STATE_MANIFEST}"

        echo "Previous manifest downloaded."

        ls -lh "${LOCAL_STATE_MANIFEST}"

        # ----------------------------------------------------
        # Parse current project
        # ----------------------------------------------------

        echo "=========================================="
        echo "Running dbt parse"
        echo "=========================================="

        dbt parse

        # ----------------------------------------------------
        # Incremental/state-aware build
        # ----------------------------------------------------

        echo "=========================================="
        echo "Running state-aware dbt build"
        echo "=========================================="

        dbt build \
            --select state:modified+ \
            --state "${LOCAL_STATE_DIR}"

    else

        echo "No previous manifest found."

        echo "Running full dbt build."

        dbt parse

        dbt build

    fi

# ============================================================
# FULL MODE
# ============================================================

else

    echo "=========================================="
    echo "FULL MODE"
    echo "=========================================="

    dbt parse

    dbt build

fi

# ============================================================
# DBT BUILD SUCCESS
# ============================================================

echo "=========================================="
echo "DBT BUILD COMPLETED"
echo "=========================================="

# ============================================================
# Generate dbt docs
# ============================================================

echo "=========================================="
echo "Generating dbt docs"
echo "=========================================="

dbt docs generate

echo "dbt docs generated successfully."

echo "=========================================="
echo "Generated target files"
echo "=========================================="

find /app/target -maxdepth 2 -type f -print

# ============================================================
# Create single-file dbt documentation
# ============================================================

echo "=========================================="
echo "Creating single-file dbt docs"
echo "=========================================="

python /app/create_single_dbt_docs.py \
    --target-dir /app/target \
    --output-file "${SINGLE_INDEX}"

# ============================================================
# Verify single HTML
# ============================================================

if [ ! -f "${SINGLE_INDEX}" ]; then

    echo "ERROR: Single dbt docs file was not created."

    exit 1

fi

echo "Single dbt docs created successfully."

ls -lh "${SINGLE_INDEX}"

FILE_SIZE=$(stat -c%s "${SINGLE_INDEX}")

echo "Single dbt docs size:"
echo "${FILE_SIZE} bytes"

# ============================================================
# Upload manifest for future state-aware runs
# ============================================================

echo "=========================================="
echo "Uploading dbt state manifest"
echo "=========================================="

aws s3 cp \
    "/app/target/manifest.json" \
    "${STATE_PATH}"

echo "Manifest uploaded successfully."

# ============================================================
# Upload single dbt docs to QA S3
# ============================================================

echo "=========================================="
echo "Uploading QA dbt docs to S3"
echo "=========================================="

QA_DOCS_KEY="qa/index.html"

echo "Bucket:"
echo "${DBT_DOCS_BUCKET}"

echo "Object:"
echo "${QA_DOCS_KEY}"

aws s3 cp \
    "${SINGLE_INDEX}" \
    "s3://${DBT_DOCS_BUCKET}/${QA_DOCS_KEY}" \
    --content-type "text/html" \
    --cache-control "no-cache"

echo "=========================================="
echo "QA DBT DOCS UPLOAD COMPLETED"
echo "=========================================="

echo "S3 object:"
echo "s3://${DBT_DOCS_BUCKET}/${QA_DOCS_KEY}"

echo "=========================================="
echo "DBT EXECUTION COMPLETED SUCCESSFULLY"
echo "=========================================="

exit 0
EOF

RUN chmod +x /app/entrypoint.sh

# ------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------

ENTRYPOINT ["/app/entrypoint.sh"]