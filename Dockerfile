FROM python:3.11-slim

WORKDIR /app

# ============================================================
# 1. Install system dependencies
# ============================================================

RUN apt-get update && \
    apt-get install -y \
        git \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# ============================================================
# 2. Install AWS CLI v2
# ============================================================

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o "/tmp/awscliv2.zip" && \
    unzip /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

# ============================================================
# 3. Install Python / dbt dependencies
# ============================================================

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

# ============================================================
# 4. Verify installations
# ============================================================

RUN python --version
RUN dbt --version
RUN aws --version

# ============================================================
# 5. Copy dbt project
# ============================================================

COPY . .

# ============================================================
# 6. Create runtime entrypoint inside the Docker image
# ============================================================

RUN cat > /app/entrypoint.sh <<'EOF'
#!/bin/sh

set -e

echo "========================================"
echo "Starting dbt container"
echo "========================================"

echo "Environment: ${ENVIRONMENT}"
echo "State Bucket: ${DBT_STATE_BUCKET}"
echo "DBT Run Mode: ${DBT_RUN_MODE}"

# ------------------------------------------------------------
# 1. Basic configuration validation
# ------------------------------------------------------------

if [ -z "${ENVIRONMENT}" ]; then
    echo "ERROR: ENVIRONMENT is not set"
    exit 1
fi

if [ -z "${DBT_STATE_BUCKET}" ]; then
    echo "ERROR: DBT_STATE_BUCKET is not set"
    exit 1
fi

if [ -z "${DBT_RUN_MODE}" ]; then
    echo "ERROR: DBT_RUN_MODE is not set"
    echo "Expected: STATE_AWARE or FULL"
    exit 1
fi

# ------------------------------------------------------------
# 2. Validate DBT_RUN_MODE
# ------------------------------------------------------------

case "${DBT_RUN_MODE}" in

    STATE_AWARE)
        echo "Run mode: STATE_AWARE"
        ;;

    FULL)
        echo "Run mode: FULL"
        ;;

    *)
        echo "ERROR: Invalid DBT_RUN_MODE"
        echo "Expected: STATE_AWARE or FULL"
        echo "Received: ${DBT_RUN_MODE}"
        exit 1
        ;;

esac

# ------------------------------------------------------------
# 3. State configuration
# ------------------------------------------------------------

STATE_KEY="${ENVIRONMENT}/manifest.json"

STATE_S3_PATH="s3://${DBT_STATE_BUCKET}/${STATE_KEY}"

STATE_DIR="/tmp/dbt-state"

STATE_MANIFEST="${STATE_DIR}/manifest.json"

mkdir -p "${STATE_DIR}"

echo "========================================"
echo "dbt state configuration"
echo "========================================"

echo "Environment     : ${ENVIRONMENT}"
echo "State S3 path   : ${STATE_S3_PATH}"
echo "State directory : ${STATE_DIR}"
echo "State manifest  : ${STATE_MANIFEST}"

# ------------------------------------------------------------
# 4. Install dbt packages
# ------------------------------------------------------------

echo "========================================"
echo "Running dbt deps"
echo "========================================"

dbt deps

# ------------------------------------------------------------
# 5. dbt debug
# ------------------------------------------------------------

echo "========================================"
echo "Running dbt debug"
echo "========================================"

dbt debug

# ------------------------------------------------------------
# 6. Check previous dbt state
# ------------------------------------------------------------

echo "========================================"
echo "Checking previous dbt state"
echo "========================================"

HAS_PREVIOUS_STATE="false"

if aws s3api head-object \
    --bucket "${DBT_STATE_BUCKET}" \
    --key "${STATE_KEY}" \
    >/dev/null 2>&1
then

    echo "Previous state FOUND"

    echo "Previous manifest location:"
    echo "${STATE_S3_PATH}"

    # --------------------------------------------------------
    # 6.1 Download previous manifest
    #     Maximum 3 attempts
    # --------------------------------------------------------

    MAX_ATTEMPTS=3

    ATTEMPT=1

    DOWNLOAD_SUCCESS="false"

    while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do

        echo "----------------------------------------"
        echo "Downloading previous manifest"
        echo "Attempt ${ATTEMPT}/${MAX_ATTEMPTS}"
        echo "----------------------------------------"

        if aws s3 cp \
            "${STATE_S3_PATH}" \
            "${STATE_MANIFEST}"
        then

            echo "Previous manifest downloaded successfully."

            DOWNLOAD_SUCCESS="true"

            break

        else

            echo "WARNING: Failed to download previous manifest."

            if [ "${ATTEMPT}" -lt "${MAX_ATTEMPTS}" ]; then

                echo "Retrying in 10 seconds..."

                sleep 10

            fi

        fi

        ATTEMPT=$((ATTEMPT + 1))

    done

    # --------------------------------------------------------
    # 6.2 Verify manifest download
    # --------------------------------------------------------

    if [ "${DOWNLOAD_SUCCESS}" != "true" ]; then

        echo "========================================"
        echo "ERROR: Previous manifest download failed"
        echo "========================================"

        echo "The manifest exists in S3, but it could not"
        echo "be downloaded after ${MAX_ATTEMPTS} attempts."

        echo "S3 path:"
        echo "${STATE_S3_PATH}"

        echo "Stopping dbt deployment."

        echo "The existing S3 manifest will NOT be modified."

        exit 1

    fi

    echo "Previous manifest downloaded:"
    ls -lh "${STATE_MANIFEST}"

    HAS_PREVIOUS_STATE="true"

else

    echo "No previous state found."

    if [ "${DBT_RUN_MODE}" = "STATE_AWARE" ]; then

        echo "This is the first STATE_AWARE deployment."

        echo "A FULL dbt build will be performed."

    else

        echo "No previous state is required for FULL mode."

    fi

fi

# ------------------------------------------------------------
# 7. Generate current dbt manifest
# ------------------------------------------------------------

echo "========================================"
echo "Generating current dbt manifest"
echo "========================================"

dbt parse

echo "Current manifest:"
ls -lh target/manifest.json

# ------------------------------------------------------------
# 8. Run dbt based on DBT_RUN_MODE
# ------------------------------------------------------------

if [ "${DBT_RUN_MODE}" = "STATE_AWARE" ]; then

    # --------------------------------------------------------
    # STATE_AWARE MODE
    # --------------------------------------------------------

    if [ "${HAS_PREVIOUS_STATE}" = "true" ]; then

        echo "========================================"
        echo "Running STATE-AWARE dbt build"
        echo "========================================"

        echo "Previous state:"
        echo "${STATE_MANIFEST}"

        echo "Selection:"
        echo "state:modified+"

        dbt build \
            --select state:modified+ \
            --state "${STATE_DIR}"

    else

        echo "========================================"
        echo "No previous state found"
        echo "Running FULL dbt build"
        echo "========================================"

        echo "This is the first deployment."

        dbt build

    fi

elif [ "${DBT_RUN_MODE}" = "FULL" ]; then

    # --------------------------------------------------------
    # FULL MODE
    # --------------------------------------------------------

    echo "========================================"
    echo "Running FULL dbt build"
    echo "========================================"

    echo "Daily scheduled execution."

    dbt build

else

    # --------------------------------------------------------
    # Safety check
    # --------------------------------------------------------

    echo "========================================"
    echo "ERROR: Invalid DBT_RUN_MODE"
    echo "========================================"

    echo "Expected:"
    echo "  STATE_AWARE"
    echo "  FULL"

    echo "Received:"
    echo "  ${DBT_RUN_MODE}"

    exit 1

fi

# ------------------------------------------------------------
# 9. dbt build succeeded
# ------------------------------------------------------------

echo "========================================"
echo "dbt build SUCCESS"
echo "========================================"

echo "Current manifest:"
ls -lh target/manifest.json

# ------------------------------------------------------------
# 10. Upload successful manifest to S3
# ------------------------------------------------------------

echo "========================================"
echo "Updating dbt state in S3"
echo "========================================"

aws s3 cp \
    target/manifest.json \
    "${STATE_S3_PATH}"

echo "========================================"
echo "DBT STATE UPDATED SUCCESSFULLY"
echo "========================================"

echo "State location:"
echo "${STATE_S3_PATH}"

echo "========================================"
echo "dbt deployment completed successfully"
echo "========================================"

EOF

# ============================================================
# 7. Make embedded entrypoint executable
# ============================================================

RUN chmod +x /app/entrypoint.sh

# ============================================================
# 8. dbt configuration
# ============================================================

ENV DBT_PROFILES_DIR=/app

# ============================================================
# 9. Container startup
# ============================================================

ENTRYPOINT ["/app/entrypoint.sh"]