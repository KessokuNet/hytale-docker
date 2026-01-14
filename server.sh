#!/bin/bash

: ${EXTRA_JVM_ARGS:=""}
: ${HYTALE_PATCHLINE:="release"}
: ${CONSOLE_PORT:="5521"}

: ${HYTALE_DATA_DIR:="/data/state"}
: ${HYTALE_BIND:="0.0.0.0:5520"}
: ${HYTALE_UNIVERSE:="/${HYTALE_DATA_DIR}/universe"}
: ${HYTALE_BACKUP_FREQUENCY:="30"}
: ${HYTALE_AUTH_MODE:="authenticated"}
: ${HYTALE_TRANSPORT:="QUIC"}
: ${HYTALE_EXTRA_ARGS:=""}
: ${HYTALE_PERSIST_AUTH:="true"}
: ${HYTALE_BOOT_CMDS:=""}

BASE_STARTUP_CMDS=()
DOWNLOAD_PATH="/data/bin"
VERSION_FILE="${DOWNLOAD_PATH}/.version"
CURRENT_VERSION=$(cat "${VERSION_FILE}" 2>/dev/null || echo "0000.00.00")
CREDS_PATH="/data/credentials.json"

DOWNLOADER=("hytale-downloader"
    "-patchline" "${HYTALE_PATCHLINE}"
    "-credentials-path" "${CREDS_PATH}"
)

if [ "${HYTALE_PERSIST_AUTH}" = "true" ]; then
    BASE_STARTUP_CMDS+=("auth persistence Encrypted")
fi

# Parse additional boot commands from HYTALE_BOOT_CMDS (semicolon-delimited)
if [ -n "${HYTALE_BOOT_CMDS}" ]; then
    IFS=';' read -ra EXTRA_CMDS <<< "${HYTALE_BOOT_CMDS}"
    for cmd in "${EXTRA_CMDS[@]}"; do
        # Trim whitespace
        cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$cmd" ]; then
            BASE_STARTUP_CMDS+=("$cmd")
        fi
    done
fi


ensure_data_dir() {
    mkdir -p "${DOWNLOAD_PATH}"
    mkdir -p "${HYTALE_DATA_DIR}"
}

downloader() {
    "${DOWNLOADER[@]}" "$@"
}

print_latest_game_version() {
    downloader -print-version
}

get_version_date() {
    echo "$1" | cut -d'-' -f1
}


ensure_data_dir

echo "Hytale Server, patchline: ${HYTALE_PATCHLINE}"
echo
echo "Checking OAuth credentials at: ${CREDS_PATH}"
echo "If OAuth credentials are expired or corrupted, delete the file and restart the container to re-authenticate."


# First time setup, enroll OAuth credentials

if [ ! -f "${CREDS_PATH}" ]; then
    echo "Credentials not found. Starting first-time authentication..."
    print_latest_game_version
else
    echo "Credentials found. Using existing credentials..."
fi

echo

echo "Fetching latest game version..."
GAME_VERSION=$(print_latest_game_version)
echo "Latest game version is: ${GAME_VERSION}"
echo "Current installed version is: ${CURRENT_VERSION}"


version_needs_update() {
    local latest="$1"
    local current="$2"
    
    # Extract just the date part (YYYY.MM.DD)
    local latest_date="${latest%-*}"
    local current_date="${current%-*}"
    
    # String comparison works because ISO format is lexicographically sortable
    [[ "${latest_date}" > "${current_date}" ]]
}

download_binaries() {
    # the downloader automatically downloads by latest version with no arguments
    downloader -download-path "${DOWNLOAD_PATH}/${GAME_VERSION}.zip"

    # Extract it to a versioned directory
    unzip "${DOWNLOAD_PATH}/${GAME_VERSION}.zip" -d "${DOWNLOAD_PATH}/${GAME_VERSION}" && \
    rm "${DOWNLOAD_PATH}/${GAME_VERSION}.zip" && \
    echo "${GAME_VERSION}" > "${VERSION_FILE}" && \
    export CURRENT_VERSION="${GAME_VERSION}"
}

if version_needs_update "${GAME_VERSION}" "${CURRENT_VERSION}"; then
    echo "A new version is available. Downloading version ${GAME_VERSION}..."
    
    # Check if the version directory already exists
    if [ -d "${DOWNLOAD_PATH}/${GAME_VERSION}" ]; then
        echo "Version ${GAME_VERSION} directory already exists, skipping download."
    else
        download_binaries
        echo "Download complete."
    fi
else
    echo "Server is up to date."
fi

SERVER_JAR_PATH="${DOWNLOAD_PATH}/${CURRENT_VERSION}/Server/HytaleServer.jar"
ASSETS_PATH="${DOWNLOAD_PATH}/${CURRENT_VERSION}/Assets.zip"

echo

echo "Starting Hytale Server version ${CURRENT_VERSION}..."

# Generate startup commands based on ${BASE_STARTUP_CMDS[@]}
# for each entry append `--boot-command`

BOOT_COMMANDS=()
for cmd in "${BASE_STARTUP_CMDS[@]}"; do
    BOOT_COMMANDS+=("--boot-command" "${cmd}")
done

SERVER_COMMAND=(java)
if [ -n "${EXTRA_JVM_ARGS}" ]; then
    read -r -a EXTRA_JVM_SPLIT <<< "${EXTRA_JVM_ARGS}"
    SERVER_COMMAND+=("${EXTRA_JVM_SPLIT[@]}")
fi

SERVER_COMMAND+=(
    -jar "${SERVER_JAR_PATH}"
    --assets "${ASSETS_PATH}"
    --bind "${HYTALE_BIND}"
    --auth-mode "${HYTALE_AUTH_MODE}"
    --transport "${HYTALE_TRANSPORT}"
    --backup-frequency "${HYTALE_BACKUP_FREQUENCY}"
    --backup-max-count "${HYTALE_BACKUP_MAX_COUNT}"
    --universe "${HYTALE_UNIVERSE}"
    "${BOOT_COMMANDS[@]}"
)

if [ -n "${HYTALE_EXTRA_ARGS}" ]; then
    read -r -a HYTALE_EXTRA_SPLIT <<< "${HYTALE_EXTRA_ARGS}"
    SERVER_COMMAND+=("${HYTALE_EXTRA_SPLIT[@]}")
fi


cd "${HYTALE_DATA_DIR}"

# Console mux using dtach: exposes a Unix socket and bridges to TCP for remote access
DTACH_SOCKET="/tmp/hytale-console"
JAVA_PID_FILE="/tmp/hytale-java.pid"
rm -f "$DTACH_SOCKET" "$JAVA_PID_FILE"

DTACH_CMD=(dtach -n "$DTACH_SOCKET")

# Launch the server inside a dtach session and record the PID so signals work
"${DTACH_CMD[@]}" sh -c 'echo $$ > /tmp/hytale-java.pid; exec "$@"' sh "${SERVER_COMMAND[@]}" &
DTACH_SERVER_PID=$!

# Wait for the PID file to appear so we can signal the JVM directly
for _ in {1..50}; do
    if [ -s "$JAVA_PID_FILE" ]; then
        JAVA_PID=$(cat "$JAVA_PID_FILE")
        break
    fi
    sleep 0.1
done

if [ -z "$JAVA_PID" ]; then
    echo "Failed to discover Java PID from dtach session; exiting"
    exit 1
fi

# Attach a read-only follower so stdout still goes to container logs
dtach -a "$DTACH_SOCKET" < /dev/null &
DTACH_LOGGER_PID=$!

# Bridge TCP console port to the dtach session
socat -d -d TCP-LISTEN:${CONSOLE_PORT},reuseaddr,fork EXEC:"dtach -a ${DTACH_SOCKET}" &
SOCKET_BRIDGE_PID=$!

# Cleanup function
CLEANED_UP=0

cleanup() {
    # Avoid double cleanup when multiple traps fire
    if [ "$CLEANED_UP" -eq 1 ]; then
        return
    fi
    CLEANED_UP=1

    echo "Shutting down Hytale server gracefully..."
    if [ -n "$JAVA_PID" ] && kill -0 $JAVA_PID 2>/dev/null; then
        # Prefer SIGTERM so Docker stop aligns with JVM expectations
        kill -TERM $JAVA_PID
        for i in {1..10}; do
            if ! kill -0 $JAVA_PID 2>/dev/null; then
                break
            fi
            sleep 1
        done
        # Last resort: SIGKILL to avoid lingering container
        if kill -0 $JAVA_PID 2>/dev/null; then
            echo "Server did not shut down gracefully, forcing termination..."
            kill -KILL $JAVA_PID 2>/dev/null
        fi
    fi

    kill $SOCKET_BRIDGE_PID $DTACH_LOGGER_PID $DTACH_SERVER_PID 2>/dev/null || true
    kill -- -$$ 2>/dev/null || true
    rm -f "$DTACH_SOCKET" "$JAVA_PID_FILE"
}

terminate() {
    cleanup
    # Exit immediately so Docker/K8s stop does not hang in wait
    exit 0
}

# Trap termination signals to run cleanup then exit; keep EXIT for normal path
trap terminate SIGTERM SIGINT SIGQUIT
trap cleanup EXIT

wait "$DTACH_SERVER_PID"
EXIT_CODE=$?

echo "Hytale server stopped with exit code $EXIT_CODE"

exit $EXIT_CODE