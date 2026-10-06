#!/bin/sh
set -e

echo "========================================"
echo "Starting dbt container"
echo "========================================"

echo "Environment: ${ENVIRONMENT}"
echo "State Bucket: ${DBT_STATE_BUCKET}"

# ------------------------------------------------------------
# 1. Basic configuration
# ------------------------------------------------------------

if [ -z "${ENVIRONMENT}" ]; then
    echo "ERROR: ENVIRONMENT is not set"
    exit 1
fi

if [ -z "${DBT_STATE_BUCKET}" ]; then
    echo "ERROR: DBT_STATE_BUCKET is not set"
    exit 1
fi

STATE_KEY="${ENVIRONMENT}/manifest.json"
STATE_S3_PATH="s3://${DBT_STATE_BUCKET}/${STATE_KEY}"
STATE_DIR="/tmp/dbt-state"
STATE_MANIFEST="${STATE_DIR}/manifest.json"

mkdir -p "${STATE_DIR}"

echo "Environment     : ${ENVIRONMENT}"
echo "State S3 path   : ${STATE_S3_PATH}"
echo "State directory : ${STATE_DIR}"

# ------------------------------------------------------------
# 2. Install dbt packages
# ------------------------------------------------------------

echo "========================================"
echo "Running dbt deps"
echo "========================================"

dbt deps

# ------------------------------------------------------------
# 3. dbt debug
# ------------------------------------------------------------

echo "========================================"
echo "Running dbt debug"
echo "========================================"

dbt debug

# ------------------------------------------------------------
# 4. Check whether previous successful state exists
# ------------------------------------------------------------

echo "========================================"
echo "Checking previous dbt state"
echo "========================================"

if aws s3api head-object \
    --bucket "${DBT_STATE_BUCKET}" \
    --key "${STATE_KEY}" \
    >/dev/null 2>&1
then

    echo "Previous state FOUND"
    echo "Previous manifest location:"
    echo "${STATE_S3_PATH}"

    # --------------------------------------------------------
    # 4.1 Download previous manifest with retry
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
    # 4.2 Verify download succeeded
    # --------------------------------------------------------

    if [ "${DOWNLOAD_SUCCESS}" != "true" ]; then

        echo "========================================"
        echo "ERROR: Previous manifest download failed"
        echo "========================================"

        echo "Manifest exists in S3, but it could not"
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
    echo "This is the first deployment."

    HAS_PREVIOUS_STATE="false"

fi

# ------------------------------------------------------------
# 5. Generate current dbt manifest
# ------------------------------------------------------------

echo "========================================"
echo "Generating current dbt manifest"
echo "========================================"

dbt parse

echo "Current manifest:"
ls -lh target/manifest.json

# ------------------------------------------------------------
# 6. Run dbt
# ------------------------------------------------------------

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
    echo "Running FULL dbt build"
    echo "========================================"

    dbt build

fi

# ------------------------------------------------------------
# 7. dbt build succeeded
# ------------------------------------------------------------

echo "========================================"
echo "dbt build SUCCESS"
echo "========================================"

echo "Current manifest:"
ls -lh target/manifest.json

# ------------------------------------------------------------
# 8. Upload NEW successful state
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