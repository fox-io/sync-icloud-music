#!/usr/bin/env python3
"""Sync local music to iCloud Drive on macOS, artist by artist."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_FILE = SCRIPT_DIR / "config.ini"
EXAMPLE_FILE = SCRIPT_DIR / "config.ini.example"

AUDIO_EXTENSIONS = frozenset({'.mp3', '.m4a', '.flac', '.aac', '.wav', '.aiff', '.alac', '.ogg'})

EXAMPLE_CONFIG = """\
# config.ini.example
# Copy this file to config.ini and edit values.

SRC=/path/to/local/music
DST=/path/to/icloud/music
LOG_DIR=/path/to/logs
MAX_LOGS=10  # optional: number of recent logs to keep, 0 disables rotation
USE_DB=yes  # optional: use sqlite cache for hashes (yes/no)
"""


# ---------------------------------------------------------------------------
# --init
# ---------------------------------------------------------------------------

def create_example() -> None:
    EXAMPLE_FILE.write_text(EXAMPLE_CONFIG)
    print(f"Created example config: {EXAMPLE_FILE}")


# ---------------------------------------------------------------------------
# Config loading (strict — mirrors bash parser behaviour exactly)
# ---------------------------------------------------------------------------

def load_config() -> dict:
    if not CONFIG_FILE.exists():
        if not EXAMPLE_FILE.exists():
            EXAMPLE_FILE.write_text(EXAMPLE_CONFIG)
            print(f"Created example config: {EXAMPLE_FILE}", file=sys.stderr)
        print(f"ERROR: config file not found: {CONFIG_FILE}", file=sys.stderr)
        print("Please copy config.ini.example to config.ini and edit it.", file=sys.stderr)
        print(f"  cp {EXAMPLE_FILE} {CONFIG_FILE}", file=sys.stderr)
        sys.exit(1)

    valid_keys = {'SRC', 'DST', 'LOG_DIR', 'MAX_LOGS', 'USE_DB'}
    # Same regex the bash uses: key starts with letter/underscore, value must
    # have at least one character and that character must not be '='.
    key_pattern = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=[^=].*$')
    config: dict[str, str] = {}

    with open(CONFIG_FILE) as fh:
        for rawline in fh:
            rawline = rawline.rstrip('\n')
            # Strip comments (everything from first '#' onward), then trim
            line = rawline.split('#')[0].strip()
            if not line:
                continue

            if not key_pattern.match(line):
                print(f"ERROR: invalid line in config: '{rawline}'", file=sys.stderr)
                sys.exit(1)

            key, _, value = line.partition('=')
            if key not in valid_keys:
                print(f"ERROR: unsupported config key: '{key}'", file=sys.stderr)
                sys.exit(1)
            config[key] = value

    for required in ('SRC', 'DST', 'LOG_DIR'):
        if not config.get(required):
            print(f"ERROR: missing required config key in {CONFIG_FILE}", file=sys.stderr)
            print("Required keys: SRC, DST, LOG_DIR", file=sys.stderr)
            sys.exit(1)

    max_logs_str = config.get('MAX_LOGS', '10')
    if not re.match(r'^[0-9]+$', max_logs_str):
        print(f"ERROR: MAX_LOGS must be a non-negative integer (got '{max_logs_str}')", file=sys.stderr)
        sys.exit(1)
    config['MAX_LOGS'] = int(max_logs_str)  # type: ignore[assignment]

    use_db_raw = config.get('USE_DB', 'yes')
    if use_db_raw.lower() in ('yes', 'y', 'true', '1'):
        config['USE_DB'] = 'yes'
    elif use_db_raw.lower() in ('no', 'n', 'false', '0'):
        config['USE_DB'] = 'no'
    else:
        print(f"ERROR: USE_DB must be yes or no (got '{use_db_raw}')", file=sys.stderr)
        sys.exit(1)

    return config


# ---------------------------------------------------------------------------
# Logger — tees every message to stdout and to the log file
# ---------------------------------------------------------------------------

class Logger:
    def __init__(self, log_path: str) -> None:
        self._log_path = log_path
        self._file = open(log_path, 'w')

    def log(self, message: str = '') -> None:
        """Print to stdout and append to log file."""
        print(message, flush=True)
        print(message, file=self._file, flush=True)

    def log_raw(self, text: str) -> None:
        """Write pre-formatted text (already contains newlines) to both destinations."""
        sys.stdout.write(text)
        sys.stdout.flush()
        self._file.write(text)
        self._file.flush()

    def log_file_only(self, text: str) -> None:
        """Write text to the log file only (mirrors bash's 2>>"$LOG")."""
        self._file.write(text)
        self._file.flush()

    def close(self) -> None:
        self._file.close()


# ---------------------------------------------------------------------------
# SQLite hash cache
# ---------------------------------------------------------------------------

class HashCache:
    def __init__(self, db_path: str, disabled: bool) -> None:
        self._disabled = disabled
        self._conn: sqlite3.Connection | None = None
        if not disabled:
            try:
                conn = sqlite3.connect(db_path)
                conn.execute(
                    'CREATE TABLE IF NOT EXISTS file_hashes'
                    '(key TEXT PRIMARY KEY, mtime INTEGER, size INTEGER, hash TEXT);'
                )
                conn.commit()
                self._conn = conn
            except Exception:
                self._disabled = True

    @property
    def skip(self) -> bool:
        return self._disabled

    def get(self, key: str, mtime: int, size: int) -> str | None:
        if self._disabled or self._conn is None:
            return None
        try:
            row = self._conn.execute(
                'SELECT hash, mtime, size FROM file_hashes WHERE key=?', (key,)
            ).fetchone()
            if row and row[1] == mtime and row[2] == size:
                return row[0]
        except Exception:
            pass
        return None

    def put(self, key: str, mtime: int, size: int, hash_val: str) -> None:
        if self._disabled or self._conn is None:
            return
        try:
            self._conn.execute(
                'INSERT OR REPLACE INTO file_hashes(key, mtime, size, hash) VALUES(?,?,?,?)',
                (key, mtime, size, hash_val),
            )
            self._conn.commit()
        except Exception:
            pass

    def close(self) -> None:
        if self._conn:
            self._conn.close()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def compute_md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def get_or_compute_hash(
    path: str,
    rel: str,
    direction: str,
    cache: HashCache,
    logger: Logger,
) -> str:
    """Return the MD5 of *path*, using the cache when possible.

    *rel* is the display path logged to the user (relative).
    *direction* is 'src' or 'dst'.
    """
    st = os.stat(path)
    mtime = int(st.st_mtime)
    size = st.st_size
    key = f"{direction}:{path}"

    cached = cache.get(key, mtime, size)
    if cached is not None:
        logger.log(f"  Using cached {direction} hash for {rel}")
        return cached

    logger.log(f"  {direction} hash missing for {rel}; computing and storing in DB")
    hash_val = compute_md5(path)
    cache.put(key, mtime, size, hash_val)
    return hash_val


def rotate_logs(log_dir: Path, max_logs: int) -> None:
    """Delete oldest sync_*.log files so at most *max_logs* remain."""
    if max_logs <= 0:
        return
    log_files = sorted(
        log_dir.glob('sync_*.log'),
        key=lambda p: p.stat().st_mtime,
    )
    to_remove = len(log_files) - max_logs
    for p in log_files[:to_remove]:
        try:
            p.unlink()
        except OSError:
            pass


def iter_audio_files(directory: Path):
    """Yield all audio files under *directory*, recursively (case-insensitive extension match)."""
    for root, dirs, files in os.walk(directory):
        dirs.sort()
        for fname in sorted(files):
            if Path(fname).suffix.lower() in AUDIO_EXTENSIONS:
                yield Path(root) / fname


# ---------------------------------------------------------------------------
# Per-artist sync + verify + evict
# ---------------------------------------------------------------------------

def sync_artist(
    artist_path: Path,
    src_root: Path,
    dst_root: Path,
    cache: HashCache,
    logger: Logger,
) -> None:
    artist_name = artist_path.name
    dst_artist_dir = dst_root / artist_name

    logger.log('-' * 48)
    logger.log(f"Processing Artist: {artist_name}")

    # 1. Sync
    rsync_cmd = [
        'rsync', '-avh',
        '--delete', '--delete-excluded', '--prune-empty-dirs',
        '--progress', '--inplace', '--partial',
        '--include=*/',
        '--include=*.mp3',
        '--include=*.m4a',
        '--include=*.flac',
        '--include=*.aac',
        '--include=*.wav',
        '--include=*.aiff',
        '--include=*.alac',
        '--include=*.ogg',
        '--exclude=.*',
        '--exclude=*',
        str(artist_path) + '/',
        str(dst_artist_dir) + '/',
    ]

    proc = subprocess.Popen(
        rsync_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    for line in proc.stdout:  # type: ignore[union-attr]
        logger.log_raw(line)
    proc.wait()
    if proc.returncode != 0:
        logger.log(f"ERROR: rsync failed for {artist_name} with exit code {proc.returncode}")
        sys.exit(proc.returncode)

    # 2. Verify
    logger.log(f"  Verifying {artist_name}...")
    sub_total = 0
    sub_fail = 0

    for src_file in iter_audio_files(artist_path):
        rel = src_file.relative_to(src_root)
        dst_file = dst_root / rel

        if not dst_file.is_file():
            continue

        src_hash = get_or_compute_hash(str(src_file), str(rel), 'src', cache, logger)
        dst_hash = get_or_compute_hash(str(dst_file), str(rel), 'dst', cache, logger)

        if src_hash == dst_hash:
            # 3. Evict immediately after successful verification
            result = subprocess.run(
                ['brctl', 'evict', str(dst_file)],
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            if result.stderr:
                logger.log_file_only(result.stderr)
            if result.returncode != 0:
                logger.log(f"  Warning: eviction failed for {rel} (file may still be uploading)")
            sub_total += 1
        else:
            logger.log(f"  MISMATCH: {rel}")
            sub_fail += 1

    logger.log(f"  Summary for {artist_name}: {sub_total} verified/evicted, {sub_fail} failed.")

    # Brief pause to let the macOS 'bird' process catch up on uploads
    time.sleep(2)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    starts_with_filter = None
    # Handle command-line arguments
    args = sys.argv[1:]
    for arg in args:
        if arg == '--init':
            create_example()
            print(f"Run: cp {EXAMPLE_FILE} {CONFIG_FILE} && edit values")
            sys.exit(0)
        elif arg.startswith('--starts-with='):
            value = arg.split('=', 1)[1]
            if value:
                starts_with_filter = value.lower()
            else:
                print("ERROR: --starts-with value cannot be empty.", file=sys.stderr)
                sys.exit(1)

    config = load_config()

    src = Path(config['SRC'])
    dst = Path(config['DST'])
    log_dir = Path(config['LOG_DIR'])
    max_logs: int = config['MAX_LOGS']  # type: ignore[assignment]
    use_db: str = config['USE_DB']

    if not src.is_dir():
        print(f"ERROR: SRC directory does not exist: {src}", file=sys.stderr)
        sys.exit(1)

    try:
        dst.mkdir(parents=True, exist_ok=True)
    except OSError:
        print(f"ERROR: failed to create DST directory: {dst}", file=sys.stderr)
        sys.exit(1)

    try:
        log_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        print(f"ERROR: failed to create LOG_DIR: {log_dir}", file=sys.stderr)
        sys.exit(1)

    log_path = log_dir / f"sync_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
    db_path = log_dir / "sync.db"

    cache = HashCache(str(db_path), disabled=(use_db == 'no'))

    logger = Logger(str(log_path))

    logger.log("=== Music Sync to iCloud (Incremental) ===")
    logger.log(f"Source:      {src}")
    logger.log(f"Destination: {dst}")
    if use_db == 'no':
        logger.log("Cache DB:    disabled by config (USE_DB=no)")
    elif not cache.skip:
        logger.log(f"Cache DB:    {db_path}")
    else:
        logger.log("Cache DB:    disabled (sqlite3 unavailable or init failed)")
    logger.log()

    try:
        # Post-logging pre-flight (mirrors the second checks in the bash script)
        if not src.is_dir():
            logger.log("ERROR: Source not found. Is the source mounted?")
            sys.exit(1)
        dst.mkdir(parents=True, exist_ok=True)

        # Process each artist directory; iterdir() includes hidden dirs (e.g. .38 Special)
        all_artist_dirs = sorted(
            (p for p in src.iterdir() if p.is_dir()),
            key=lambda p: p.name,
        )

        artist_dirs_to_sync = all_artist_dirs
        if starts_with_filter:
            logger.log(f"Filtering artists to those starting with '{starts_with_filter}' (case-insensitive).")
            artist_dirs_to_sync = [
                p for p in all_artist_dirs if p.name.lower().startswith(starts_with_filter)
            ]

        for artist_path in artist_dirs_to_sync:
            sync_artist(artist_path, src, dst, cache, logger)

        # Clean up orphaned artist directories in destination
        if starts_with_filter:
            logger.log("Skipping orphan directory cleanup due to --starts-with filter.")
        else:
            existing_artists = {p.name for p in all_artist_dirs}
            for dst_artist in dst.iterdir():
                if dst_artist.is_dir() and dst_artist.name not in existing_artists:
                    logger.log(f"Removing orphaned artist directory: {dst_artist.name}")
                    try:
                        shutil.rmtree(dst_artist)
                    except OSError as e:
                        logger.log(f"Failed to remove {dst_artist}: {e}")

        logger.log()
        logger.log("=== Global Sync Complete ===")
        logger.log(f"Full log saved to: {log_path}")

    except KeyboardInterrupt:
        logger.log("Sync interrupted by user")

    finally:
        cache.close()
        logger.close()
        rotate_logs(log_dir, max_logs)


if __name__ == '__main__':
    main()
