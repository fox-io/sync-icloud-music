#!/bin/bash
# Revised Sync Script for macOS Tahoe - Artist-by-Artist Loop
set -euo pipefail

# --- Command-line options ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.ini"
EXAMPLE_FILE="$SCRIPT_DIR/config.ini.example"

create_example() {
    cat > "$EXAMPLE_FILE" <<'EOF'
# config.ini.example
# Copy this file to config.ini and edit values.

SRC=/path/to/local/music
DST=/path/to/icloud/music
LOG_DIR=/path/to/logs
MAX_LOGS=10  # optional: number of recent logs to keep, 0 disables rotation
EOF
    echo "Created example config: $EXAMPLE_FILE"
}

if [ "${1:-}" = "--init" ]; then
    create_example
    echo "Run: cp $EXAMPLE_FILE $CONFIG_FILE && edit values"
    exit 0
fi

# --- Config loading (strict) ---
# The config file must exist in the same directory as this script.

if [ ! -f "$CONFIG_FILE" ]; then
    if [ ! -f "$EXAMPLE_FILE" ]; then
        cat > "$EXAMPLE_FILE" <<'EOF'
# config.ini.example
# Copy this file to config.ini and edit values.

SRC=/path/to/local/music
DST=/path/to/icloud/music
LOG_DIR=/path/to/logs
EOF
        echo "Created example config: $EXAMPLE_FILE" >&2
    fi

    echo "ERROR: config file not found: $CONFIG_FILE" >&2
    echo "Please copy config.ini.example to config.ini and edit it." >&2
    echo "  cp $EXAMPLE_FILE $CONFIG_FILE" >&2
    exit 1
fi

SRC=""
DST=""
LOG_DIR=""

while IFS= read -r rawline || [ -n "$rawline" ]; do
    line="${rawline%%#*}"         # strip comments
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//')"  # trim
    [ -z "$line" ] && continue

    if ! echo "$line" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=[^=].*$'; then
        echo "ERROR: invalid line in config: '$rawline'" >&2
        exit 1
    fi

    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
        SRC) SRC="$value" ;;
        DST) DST="$value" ;;
        LOG_DIR) LOG_DIR="$value" ;;
        MAX_LOGS) MAX_LOGS="$value" ;;
        *)
            echo "ERROR: unsupported config key: '$key'" >&2
            exit 1
            ;;
    esac

done < "$CONFIG_FILE"

if [ -z "$SRC" ] || [ -z "$DST" ] || [ -z "$LOG_DIR" ]; then
    echo "ERROR: missing required config key in $CONFIG_FILE" >&2
    echo "Required keys: SRC, DST, LOG_DIR" >&2
    exit 1
fi

MAX_LOGS="${MAX_LOGS:-10}"
if ! echo "$MAX_LOGS" | grep -Eq '^[0-9]+$'; then
    echo "ERROR: MAX_LOGS must be a non-negative integer (got '$MAX_LOGS')" >&2
    exit 1
fi

if [ ! -d "$SRC" ]; then
    echo "ERROR: SRC directory does not exist: $SRC" >&2
    exit 1
fi

mkdir -p "$DST" 2>/dev/null || {
    echo "ERROR: failed to create DST directory: $DST" >&2
    exit 1
}

mkdir -p "$LOG_DIR" 2>/dev/null || {
    echo "ERROR: failed to create LOG_DIR: $LOG_DIR" >&2
    exit 1
}

LOG="$LOG_DIR/sync_music_$(date +%Y%m%d_%H%M%S).log"

# --- Log rotation ---
if [ "$MAX_LOGS" -gt 0 ]; then
    mapfile -t LOGGER_FILES < <(find "$LOG_DIR" -maxdepth 1 -type f -name 'sync_music_*.log' -print0 | xargs -0 -n1 stat -f '%m %N' | sort -n | awk '{$1=""; sub(/^ /,""); print}')
    total=${#LOGGER_FILES[@]}
    if [ "$total" -gt "$MAX_LOGS" ]; then
        to_remove=$((total - MAX_LOGS))
        for i in $(seq 0 $((to_remove - 1))); do
            rm -f "${LOGGER_FILES[$i]}" || true
        done
    fi
fi

echo "=== Music Sync to iCloud (Incremental) ===" | tee "$LOG"
echo "Source:      $SRC" | tee -a "$LOG"
echo "Destination: $DST" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# --- Pre-flight checks ---
if [ ! -d "$SRC" ]; then
    echo "ERROR: Source not found. Is the source mounted?" | tee -a "$LOG"
    exit 1
fi
mkdir -p "$DST"
# --- Main Processing Loop ---
# This loop processes each Artist folder individually to save local disk space.
for artist_path in "$SRC"/*/; do
    artist_name=$(basename "$artist_path")
    
    echo "------------------------------------------------" | tee -a "$LOG"
    echo "Processing Artist: $artist_name" | tee -a "$LOG"
    
    # 1. Sync current artist folder
    # --delete: remove destination files that no longer exist in source (renamed/deleted)
    # --inplace: prevent double-caching locally
    # --partial: handles 'Broken Pipe' by resuming partial files
    rsync -avh --delete --progress --inplace --partial "$artist_path" "$DST/$artist_name/" 2>&1 | tee -a "$LOG"
    
    # 2. Verify current artist folder
    echo "  Verifying $artist_name..." | tee -a "$LOG"
    SUB_TOTAL=0
    SUB_FAIL=0
    
    while IFS= read -r -d '' src_file; do
        rel="${src_file#"$SRC"/}"
        dst_file="$DST/$rel"
        
        if [ -f "$dst_file" ]; then
            src_hash=$(md5 -q "$src_file")
            dst_hash=$(md5 -q "$dst_file")
            
            if [ "$src_hash" = "$dst_hash" ]; then
                # 3. Evict immediately after successful verification
                # Note: Eviction only fully clears space once the upload finishes
                brctl evict "$dst_file" 2>>"$LOG" || echo "  Warning: eviction failed for $rel (file may still be uploading)" | tee -a "$LOG"
                SUB_TOTAL=$((SUB_TOTAL + 1))
            else
                echo "  MISMATCH: $rel" | tee -a "$LOG"
                SUB_FAIL=$((SUB_FAIL + 1))
            fi
        fi
    done < <(find "$artist_path" -type f -print0)
    
    echo "  Summary for $artist_name: $SUB_TOTAL verified/evicted, $SUB_FAIL failed." | tee -a "$LOG"
    
    # Optional: Brief pause to let the macOS 'bird' process catch up on uploads
    sleep 2
done

echo "" | tee -a "$LOG"
echo "=== Global Sync Complete ===" | tee -a "$LOG"
echo "Full log saved to: $LOG" | tee -a "$LOG"