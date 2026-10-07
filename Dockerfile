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
# 6. Create entrypoint script
# ============================================================

RUN cat > /app/entrypoint.sh <<'EOF'
#!/bin/sh

set -e

echo "========================================"
echo "Starting dbt container"
echo "========================================"

echo "Environment : ${ENVIRONMENT}"
echo "Run Mode    : ${DBT_RUN_MODE}"
echo "State Bucket: ${DBT_STATE_BUCKET}"

# ============================================================
# 1. Basic configuration
# ============================================================

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
    echo "Expected values: STATE_AWARE or FULL"
    exit 1
fi

if [ "${DBT_RUN_MODE}" != "STATE_AWARE" ] && \
   [ "${DBT_RUN_MODE}" != "FULL" ]; then
    echo "ERROR: Invalid DBT_RUN_MODE: ${DBT_RUN_MODE}"
    echo "Expected values: STATE_AWARE or FULL"
    exit 1
fi

STATE_KEY="${ENVIRONMENT}/manifest.json"
STATE_S3_PATH="s3://${DBT_STATE_BUCKET}/${STATE_KEY}"
STATE_DIR="/tmp/dbt-state"
STATE_MANIFEST="${STATE_DIR}/manifest.json"

mkdir -p "${STATE_DIR}"

echo "========================================"
echo "dbt Configuration"
echo "========================================"

echo "Environment     : ${ENVIRONMENT}"
echo "Run Mode        : ${DBT_RUN_MODE}"
echo "State S3 path   : ${STATE_S3_PATH}"
echo "State directory : ${STATE_DIR}"

# ============================================================
# 2. Install dbt packages
# ============================================================

echo "========================================"
echo "Running dbt deps"
echo "========================================"

dbt deps

# ============================================================
# 3. dbt debug
# ============================================================

echo "========================================"
echo "Running dbt debug"
echo "========================================"

dbt debug

# ============================================================
# 4. STATE-AWARE OR FULL EXECUTION
# ============================================================

if [ "${DBT_RUN_MODE}" = "STATE_AWARE" ]; then

    # ========================================================
    # STATE-AWARE MODE
    # ========================================================

    echo "========================================"
    echo "STATE-AWARE MODE"
    echo "========================================"

    echo "Checking previous dbt state..."

    if aws s3api head-object \
        --bucket "${DBT_STATE_BUCKET}" \
        --key "${STATE_KEY}" \
        >/dev/null 2>&1
    then

        echo "Previous state FOUND"
        echo "Previous manifest:"
        echo "${STATE_S3_PATH}"

        # ----------------------------------------------------
        # Download previous manifest with 3 attempts
        # ----------------------------------------------------

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

        # ----------------------------------------------------
        # Verify manifest download
        # ----------------------------------------------------

        if [ "${DOWNLOAD_SUCCESS}" != "true" ]; then

            echo "========================================"
            echo "ERROR: Previous manifest download failed"
            echo "========================================"

            echo "Manifest exists in S3, but it could not"
            echo "be downloaded after ${MAX_ATTEMPTS} attempts."

            echo "S3 path:"
            echo "${STATE_S3_PATH}"

            echo "Stopping state-aware execution."

            exit 1
        fi

        echo "Previous manifest downloaded:"
        ls -lh "${STATE_MANIFEST}"

        HAS_PREVIOUS_STATE="true"

    else

        echo "No previous state found."
        echo "Running FULL dbt build for first deployment."

        HAS_PREVIOUS_STATE="false"

    fi

    # --------------------------------------------------------
    # Generate current manifest
    # --------------------------------------------------------

    echo "========================================"
    echo "Generating current dbt manifest"
    echo "========================================"

    dbt parse

    echo "Current manifest:"
    ls -lh target/manifest.json

    # --------------------------------------------------------
    # Run dbt
    # --------------------------------------------------------

    if [ "${HAS_PREVIOUS_STATE}" = "true" ]; then

        echo "========================================"
        echo "Running STATE-AWARE dbt build"
        echo "========================================"

        echo "Selection:"
        echo "state:modified+"

        dbt build \
            --select state:modified+ \
            --state "${STATE_DIR}"

    else

        echo "========================================"
        echo "Running FULL dbt build"
        echo "========================================"

        dbt build

    fi

else

    # ========================================================
    # FULL MODE
    # ========================================================

    echo "========================================"
    echo "FULL MODE"
    echo "========================================"

    echo "Daily PROD execution."
    echo "Previous manifest will NOT be downloaded."
    echo "State comparison will NOT be performed."

    # --------------------------------------------------------
    # Generate current manifest
    # --------------------------------------------------------

    echo "========================================"
    echo "Generating current dbt manifest"
    echo "========================================"

    dbt parse

    echo "Current manifest:"
    ls -lh target/manifest.json

    # --------------------------------------------------------
    # Run full dbt build
    # --------------------------------------------------------

    echo "========================================"
    echo "Running FULL dbt build"
    echo "========================================"

    echo "Selection:"
    echo "ALL enabled dbt models"

    dbt build

fi

# ============================================================
# 5. dbt build succeeded
# ============================================================

echo "========================================"
echo "dbt build SUCCESS"
echo "========================================"

echo "Current manifest:"
ls -lh target/manifest.json

# ============================================================
# 6. Upload NEW successful manifest
# ============================================================

echo "========================================"
echo "Updating dbt state in S3"
echo "========================================"

echo "Uploading:"
echo "target/manifest.json"

echo "To:"
echo "${STATE_S3_PATH}"

aws s3 cp \
    target/manifest.json \
    "${STATE_S3_PATH}"

echo "========================================"
echo "DBT STATE UPDATED SUCCESSFULLY"
echo "========================================"

echo "State location:"
echo "${STATE_S3_PATH}"

echo "========================================"
echo "dbt execution completed successfully"
echo "========================================"
EOF

# ============================================================
# 7. Make entrypoint executable
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