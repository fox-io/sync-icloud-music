# sync-icloud-music

A Bash script for incrementally syncing local music files to iCloud Drive on macOS, with artist-by-artist processing, file verification, and automatic log rotation.

## Features

- **Incremental Sync**: Uses `rsync` to sync only changed files, preserving bandwidth and time.
- **Artist-by-Artist Processing**: Processes each artist folder individually to minimize local disk usage.
- **File Verification**: Verifies synced files with MD5 hashes and evicts them from local storage after successful upload.
- **SQLite Hash Cache**: Optionally caches file hashes in `sync.db` so unchanged files don’t need to be re-hashed on every run.
- **Audio-only Sync**: Syncs only audio files and skips hidden/non-audio items like `.DS_Store`.
- **Log Rotation**: Automatically rotates logs to keep a configurable number of recent log files.
- **Strict Configuration**: Requires a `config.ini` file with no hardcoded defaults for security and portability.
- **GitHub-Friendly**: No PII in the script; configuration is external and ignored by Git.

## Prerequisites

- macOS (tested on macOS Tahoe)
- Bash (default shell)
- `rsync` (pre-installed on macOS)
- `md5` (pre-installed on macOS)
- `brctl` (for iCloud eviction, part of macOS)

## Installation

1. Clone or download the repository:
   ```bash
   git clone https://github.com/yourusername/sync-icloud-music.git
   cd sync-icloud-music
   ```

2. Initialize the example configuration:
   ```bash
   ./sync-icloud-music.sh --init
   ```

3. Copy and edit the configuration:
   ```bash
   cp config.ini.example config.ini
   # Edit config.ini with your paths
   ```

## Configuration

Create a `config.ini` file in the same directory as the script. Required keys:

- `SRC`: Path to your local music directory (e.g., `/Volumes/ExternalDrive/music`)
- `DST`: Path to your iCloud Drive music directory (e.g., `/Users/username/Library/Mobile Documents/com~apple~CloudDocs/Music`)
- `LOG_DIR`: Directory to store log files and optional `sync.db` cache (e.g., `/Users/username/logs`)
- `MAX_LOGS`: Number of recent log files to keep (optional, default 10; set to 0 to disable rotation)
- `USE_DB`: Optional cache toggle; `yes` enables SQLite hash caching, `no` disables it (default `yes`).

Example `config.ini`:

```ini
SRC=/Volumes/ExternalDrive/music
DST=/Users/username/Library/Mobile Documents/com~apple~CloudDocs/Music
LOG_DIR=/Users/username/logs
MAX_LOGS=10
```

**Note**: `config.ini` is ignored by Git for security. Use `config.ini.example` as a template.

## Usage

Run the script:

```bash
./sync-icloud-music.sh
```

The script will:
1. Load configuration from `config.ini`.
2. Perform pre-flight checks (source exists, destinations creatable).
3. Rotate logs if `MAX_LOGS > 0`.
4. Sync each artist folder incrementally.
5. Verify and evict files after sync.
6. Log all output to a timestamped file in `LOG_DIR`.

### Options

- `--init`: Generate `config.ini.example` and exit.

## Logs

Logs are saved to `LOG_DIR/sync_YYYYMMDD_HHMMSS.log`. The script rotates logs based on `MAX_LOGS`, keeping the most recent files and deleting older ones. If `USE_DB=yes`, the script also creates `LOG_DIR/sync.db` to cache file hashes.

## Troubleshooting

- **Source not found**: Ensure `SRC` path exists and is mounted.
- **Config errors**: Check `config.ini` for required keys and valid values.
- **Permission issues**: Ensure write access to `DST` and `LOG_DIR`.
- **iCloud upload delays**: Eviction may fail if uploads are still in progress; the script logs warnings in such cases.

## Contributing

Contributions are welcome! Please:
1. Fork the repository.
2. Create a feature branch.
3. Submit a pull request with a clear description.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.