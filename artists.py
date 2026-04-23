import sqlite3
from pathlib import Path
import sys

# Configuration
DB_PATH = Path("artists.sqlite3")
SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_FILE = SCRIPT_DIR / "config.ini"

def load_src_path() -> Path:
    """Loads the SRC path from config.ini."""
    if not CONFIG_FILE.exists():
        print(f"ERROR: config file not found: {CONFIG_FILE}", file=sys.stderr)
        print("Please run 'sync-icloud-music.py --init' to create a configuration file.", file=sys.stderr)
        sys.exit(1)

    src_path_str = None
    with open(CONFIG_FILE) as fh:
        for rawline in fh:
            line = rawline.split('#')[0].strip()
            if not line:
                continue
            key, _, value = line.partition('=')
            if key.strip() == 'SRC':
                src_path_str = value.strip()
                break
    if src_path_str is None:
        print(f"ERROR: missing required config key 'SRC' in {CONFIG_FILE}", file=sys.stderr)
        sys.exit(1)
    return Path(src_path_str)

def init_database():
    """Initializes the database by creating the 'artists' table if it doesn't exist."""
    print(f"Initializing database: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS "artists" (
            name TEXT UNIQUE,
            processed INTEGER DEFAULT 0
        );
    """)
    conn.commit()
    conn.close()
    print("Database initialized successfully.")

def sync_database():
    MUSIC_DIR = load_src_path()

    # Ensure the database exists
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS "artists" (
        name TEXT UNIQUE,
        processed INTEGER DEFAULT 0
    );
    """)

    # 1. Get current artist folders (directories only, no hidden files)
    if not MUSIC_DIR.exists():
        print(f"Error: {MUSIC_DIR} directory not found.")
        conn.close()

    # Use a generator to find all subdirectories in ./music
    folder_names = [f.name for f in MUSIC_DIR.iterdir() if f.is_dir() and not f.name.startswith('.')]

    print(f"Found {len(folder_names)} artist folders in {MUSIC_DIR}...")

    # 2. Logic: Insert only if the name doesn't exist
    # This prevents overwriting the 'processed' status of existing artists.
    sql = """
    INSERT OR IGNORE INTO artists (name, processed)
    VALUES (?, 0)
    """

    new_artists_count = 0
    for name in folder_names:
        cursor.execute(sql, (name,))
        if cursor.rowcount > 0:
            new_artists_count += 1

    # 3. Commit and wrap up
    conn.commit()
    conn.close()

    print(f"Done! Added {new_artists_count} new artists to the database.")

def main():
    """Parses command-line arguments and runs the appropriate function."""
    if "--init" in sys.argv:
        init_database()
    else:
        sync_database()

if __name__ == "__main__":
    main()