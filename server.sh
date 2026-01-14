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


cd "${HYTALE_DATA_DIR}"

# Setup console multiplexing for telnet access
# Create named pipes for bidirectional communication
STDIN_FIFO="/tmp/hytale-stdin"
rm -f "$STDIN_FIFO"
mkfifo "$STDIN_FIFO"

# Start socat for remote console access - creates PTY
socat -d -d PTY,link=/tmp/hytale-pty,raw,echo=0 TCP-LISTEN:${CONSOLE_PORT},reuseaddr,fork &
SOCAT_PID=$!

# Give socat time to create the PTY
sleep 1

# Bridge PTY input to stdin FIFO in background
cat /tmp/hytale-pty > "$STDIN_FIFO" &
PTY_READER_PID=$!

# Start stdin cat in background
cat < /dev/stdin > "$STDIN_FIFO" &
STDIN_CAT_PID=$!

# Cleanup function
cleanup() {
    echo "Shutting down Hytale server gracefully..."
    if [ -n "$JAVA_PID" ] && kill -0 $JAVA_PID 2>/dev/null; then
        # Send SIGINT to Java process for graceful shutdown
        kill -INT $JAVA_PID
        # Wait for server to shut down (with timeout)
        for i in {1..30}; do
            if ! kill -0 $JAVA_PID 2>/dev/null; then
                break
            fi
            sleep 1
        done
        # Force kill if still running
        if kill -0 $JAVA_PID 2>/dev/null; then
            echo "Server did not shut down gracefully, forcing termination..."
            kill -9 $JAVA_PID 2>/dev/null
        fi
    fi
    # Kill all processes in this process group
    kill -- -$$ 2>/dev/null || true
    # Clean up files
    rm -f /tmp/hytale-pty "$STDIN_FIFO"
}

# Trap termination signals AND exit
trap cleanup SIGTERM SIGINT SIGQUIT EXIT

# Run Java server with multiplexed I/O:
# - stdin comes from FIFO (which gets input from both docker stdin and PTY)
# - stdout/stderr goes to console (docker logs) AND optionally to PTY (if clients connected)
# Using process substitution to prevent PTY writes from blocking
cat "$STDIN_FIFO" | \
java ${EXTRA_JVM_ARGS} -jar "${SERVER_JAR_PATH}" \
    --assets "${ASSETS_PATH}" \
    --bind "${HYTALE_BIND}" \
    --auth-mode "${HYTALE_AUTH_MODE}" \
    --transport "${HYTALE_TRANSPORT}" \
    --backup-frequency "${HYTALE_BACKUP_FREQUENCY}" \
    --backup-max-count "${HYTALE_BACKUP_MAX_COUNT}" \
    --universe "${HYTALE_UNIVERSE}" \
    "${BOOT_COMMANDS[@]}" \
    ${HYTALE_EXTRA_ARGS} 2>&1 | tee >(cat > /tmp/hytale-pty 2>/dev/null || true) &

JAVA_PID=$!

# Wait for Java process to exit
wait $JAVA_PID
EXIT_CODE=$?

echo "Hytale server stopped with exit code $EXIT_CODE"

# Kill all background processes explicitly before exit
kill $SOCAT_PID $PTY_READER_PID $STDIN_CAT_PID 2>/dev/null || true
kill $(jobs -p) 2>/dev/null || true

# Exit immediately (cleanup will be called via EXIT trap)
exit $EXIT_CODE