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
USE_DB=yes  # optional: use sqlite cache for hashes (yes/no)
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
MAX_LOGS=10
USE_DB=yes
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
        USE_DB) USE_DB="$value" ;;
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
USE_DB="${USE_DB:-yes}"
if ! echo "$MAX_LOGS" | grep -Eq '^[0-9]+$'; then
    echo "ERROR: MAX_LOGS must be a non-negative integer (got '$MAX_LOGS')" >&2
    exit 1
fi

USE_DB_LOWER="$(printf '%s' "$USE_DB" | tr '[:upper:]' '[:lower:]')"
case "$USE_DB_LOWER" in
    yes|y|true|1)
        USE_DB=yes
        ;;
    no|n|false|0)
        USE_DB=no
        ;;
    *)
        echo "ERROR: USE_DB must be yes or no (got '$USE_DB')" >&2
        exit 1
        ;;
esac

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

LOG="$LOG_DIR/sync_$(date +%Y%m%d_%H%M%S).log"
DB_FILE="$LOG_DIR/sync.db"
SKIP_DB=0
if [ "$USE_DB" = "no" ]; then
    SKIP_DB=1
fi

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

db_init() {
    if [ "$SKIP_DB" -ne 0 ]; then
        return
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        SKIP_DB=1
        return
    fi

    sqlite3 "$DB_FILE" 'CREATE TABLE IF NOT EXISTS file_hashes(key TEXT PRIMARY KEY, mtime INTEGER, size INTEGER, hash TEXT);' 2>/dev/null || SKIP_DB=1
}

db_get_row() {
    local key
    key="$(sql_escape "$1")"
    sqlite3 "$DB_FILE" "SELECT hash,mtime,size FROM file_hashes WHERE key='$key';" 2>/dev/null
}

get_cached_hash() {
    if [ "$SKIP_DB" -ne 0 ]; then
        return 1
    fi

    local key="$1"
    local mtime="$2"
    local size="$3"
    local row cached_hash cached_mtime cached_size

    row="$(db_get_row "$key")"
    IFS='|' read -r cached_hash cached_mtime cached_size <<< "$row"

    if [ -n "$cached_hash" ] && [ "$cached_mtime" = "$mtime" ] && [ "$cached_size" = "$size" ]; then
        printf '%s' "$cached_hash"
        return 0
    fi

    return 1
}

update_cached_hash() {
    if [ "$SKIP_DB" -ne 0 ]; then
        return
    fi

    local key="$(sql_escape "$1")"
    local mtime="$2"
    local size="$3"
    local hash="$(sql_escape "$4")"

    sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO file_hashes(key,mtime,size,hash) VALUES('$key',$mtime,$size,'$hash');" 2>/dev/null || true
}

db_init

# --- Log rotation ---
if [ "$MAX_LOGS" -gt 0 ]; then
    LOGGER_FILES=()
    while IFS= read -r file; do
        LOGGER_FILES+=("$file")
    done < <(find "$LOG_DIR" -maxdepth 1 -type f -name 'sync_*.log' -print0 | xargs -0 -n1 stat -f '%m %N' | sort -n | awk '{$1=""; sub(/^ /,""); print}')
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
if [ "$USE_DB" = "no" ]; then
    echo "Cache DB:    disabled by config (USE_DB=no)" | tee -a "$LOG"
elif [ "$SKIP_DB" -eq 0 ]; then
    echo "Cache DB:    $DB_FILE" | tee -a "$LOG"
else
    echo "Cache DB:    disabled (sqlite3 unavailable or init failed)" | tee -a "$LOG"
fi
 echo "" | tee -a "$LOG"

# --- Pre-flight checks ---
if [ ! -d "$SRC" ]; then
    echo "ERROR: Source not found. Is the source mounted?" | tee -a "$LOG"
    exit 1
fi
mkdir -p "$DST"
# --- Main Processing Loop ---
# This loop processes each Artist folder individually to save local disk space.
# Enable dotglob so artist folders beginning with a dot are included, e.g. .38 Special.
(
    shopt -s dotglob nullglob
    for artist_path in "$SRC"/*/; do
        artist_name=$(basename "$artist_path")
        
        echo "------------------------------------------------" | tee -a "$LOG"
        echo "Processing Artist: $artist_name" | tee -a "$LOG"
    
    # 1. Sync current artist folder
    # --delete: remove destination files that no longer exist in source (renamed/deleted)
    # --delete-excluded: remove excluded files from destination too
    # --inplace: prevent double-caching locally
    # --partial: handles 'Broken Pipe' by resuming partial files
    rsync -avh --delete --delete-excluded --prune-empty-dirs --progress --inplace --partial \
        --include='*/' \
        --include='*.mp3' \
        --include='*.m4a' \
        --include='*.flac' \
        --include='*.aac' \
        --include='*.wav' \
        --include='*.aiff' \
        --include='*.alac' \
        --include='*.ogg' \
        --exclude='.*' \
        --exclude='*' \
        "$artist_path" "$DST/$artist_name/" 2>&1 | tee -a "$LOG"
    
    # 2. Verify current artist folder
    echo "  Verifying $artist_name..." | tee -a "$LOG"
    SUB_TOTAL=0
    SUB_FAIL=0
    
    while IFS= read -r -d '' src_file; do
        rel="${src_file#"$SRC"/}"
        dst_file="$DST/$rel"
        
        if [ -f "$dst_file" ]; then
            src_size=$(stat -f%z "$src_file")
            src_mtime=$(stat -f%m "$src_file")
            dst_size=$(stat -f%z "$dst_file")
            dst_mtime=$(stat -f%m "$dst_file")

            if src_hash=$(get_cached_hash "src:$src_file" "$src_mtime" "$src_size"); then
                echo "  Using cached src hash for $rel" | tee -a "$LOG"
            else
                echo "  src hash missing for $rel; computing and storing in DB" | tee -a "$LOG"
                src_hash=$(md5 -q "$src_file")
                update_cached_hash "src:$src_file" "$src_mtime" "$src_size" "$src_hash"
            fi

            if dst_hash=$(get_cached_hash "dst:$dst_file" "$dst_mtime" "$dst_size"); then
                echo "  Using cached dst hash for $rel" | tee -a "$LOG"
            else
                echo "  dst hash missing for $rel; computing and storing in DB" | tee -a "$LOG"
                dst_hash=$(md5 -q "$dst_file")
                update_cached_hash "dst:$dst_file" "$dst_mtime" "$dst_size" "$dst_hash"
            fi

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
    done < <(find "$artist_path" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.flac' -o -iname '*.aac' -o -iname '*.wav' -o -iname '*.aiff' -o -iname '*.alac' -o -iname '*.ogg' \) -print0)
    
    echo "  Summary for $artist_name: $SUB_TOTAL verified/evicted, $SUB_FAIL failed." | tee -a "$LOG"
    
    # Optional: Brief pause to let the macOS 'bird' process catch up on uploads
    sleep 2
    done
)

echo "" | tee -a "$LOG"
echo "=== Global Sync Complete ===" | tee -a "$LOG"
echo "Full log saved to: $LOG" | tee -a "$LOG"