#!/usr/bin/env bash
# install.oreilly.books.sh — install and launch the O'Reilly free-link tool.
# Supports Termux and Debian/Ubuntu (including proot-distro) without running as root.
set -Eeuo pipefail

# Keep logs readable and report the failing command for diagnosis.
SCRIPT_NAME="install.oreilly.books.sh"
INSTALL_DIR="${HOME}/oreilly-books"
BIN_DIR="${HOME}/bin"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S' 2>/dev/null || printf 'time')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# Show the actual account and refuse to run the installer itself as root.
CURRENT_USER="$(id -un 2>/dev/null || printf unknown)"
printf '\n=== OReilly Free Ebook Link Tool Installer ===\n'
printf 'Username running installer: %s\n' "$CURRENT_USER"
printf 'UID: %s\n' "$(id -u 2>/dev/null || printf unknown)"
if [ "$(id -u 2>/dev/null || printf 0)" -eq 0 ]; then
    die "Do not run this installer as root. Log in as a normal Termux/Debian user and retry."
fi

# Detect Termux versus Debian-like environments.
case "${PREFIX:-}" in
    */com.termux/files/usr) PLATFORM="termux" ;;
    *) 
        if [ -f /etc/debian_version ] || command -v apt-get >/dev/null 2>&1; then
            PLATFORM="debian"
        else
            PLATFORM="unknown"
        fi
        ;;
esac
log "Detected platform: ${PLATFORM}"

# Install a package only when the command is missing; do not repeatedly update apt.
install_package() {
    local package="$1"
    if [ "$PLATFORM" = "termux" ]; then
        command -v pkg >/dev/null 2>&1 || die "Termux pkg command not found."
        log "Installing missing package with: pkg install ${package} -y"
        pkg install "$package" -y || {
            log "Package install failed; refreshing Termux package metadata once."
            pkg update -y || true
            pkg install "$package" -y || die "Could not install ${package}."
        }
    elif [ "$PLATFORM" = "debian" ]; then
        command -v apt-get >/dev/null 2>&1 || die "apt-get not found."
        if command -v sudo >/dev/null 2>&1; then
            log "Installing missing package with sudo apt-get install -y ${package}"
            sudo apt-get install -y "$package" || {
                log "Trying one apt metadata refresh, then retrying package install."
                sudo apt-get update || true
                sudo apt-get install -y "$package" || die "Could not install ${package}."
            }
        else
            die "Missing dependency '${package}'. Install it as root using apt, then rerun as ${CURRENT_USER}; do not run this script as root."
        fi
    else
        die "Unsupported platform. Use Termux or Debian/Ubuntu."
    fi
}

# Ensure Python 3 is present. The Python application uses only its standard library.
if ! command -v python3 >/dev/null 2>&1; then
    install_package python
fi
command -v python3 >/dev/null 2>&1 || die "python3 is still unavailable after installation."

# curl is only needed to download the Python script from a hosting URL.
if ! command -v curl >/dev/null 2>&1; then
    install_package curl
fi
command -v curl >/dev/null 2>&1 || die "curl is still unavailable after installation."

# Create the install locations and make sure the current user owns them.
mkdir -p "$INSTALL_DIR" "$BIN_DIR" || die "Cannot create install directories under HOME=${HOME}."
PY_TARGET="${INSTALL_DIR}/oreilly_3.py"
SH_TARGET="${BIN_DIR}/install.oreilly.books.sh"

# If a local copy of oreilly_3.py sits beside this installer, prefer it.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -f "${SCRIPT_DIR}/oreilly_3.py" ]; then
    # Prefer the adjacent script when the user downloaded the complete bundle.
    cp "${SCRIPT_DIR}/oreilly_3.py" "$PY_TARGET" || die "Could not copy oreilly_3.py."
else
    # Standalone mode: embed the application so curl-running this installer needs no second URL.
    log "No adjacent oreilly_3.py found; installing the embedded application."
    cat > "$PY_TARGET" <<'OREILLY_PYTHON_APP'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
oreilly_3.py — conservative O'Reilly free-book link finder/downloader.

This is a clean rewrite inspired by the two legacy scripts linked by the user.
It uses only Python's standard library, avoids fake form submissions, and only
downloads files linked publicly from pages it can access without authentication.
Website structure and availability can change; no scraper can guarantee success.
"""

import argparse
import concurrent.futures
import html
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

# Use a clear user agent and finite timeouts to avoid hanging on mobile networks.
USER_AGENT = "oreilly-free-link-tool/3.0 (Python urllib; respectful public-link fetcher)"
TIMEOUT = 25
RETRIES = 2
DEFAULT_START = "https://www.oreilly.com/free/"
ALLOWED_EXTENSIONS = {".pdf", ".epub", ".mobi"}
SKIP_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".svg", ".css", ".js"}
MAX_PAGE_BYTES = 5 * 1024 * 1024


def log(level, message):
    """Print a timestamped status line."""
    stamp = time.strftime("%H:%M:%S")
    print(f"[{stamp}] [{level}] {message}", flush=True)


class LinkParser(HTMLParser):
    """Collect anchor hrefs and useful page titles without third-party modules."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links = []
        self._in_title = False
        self.title_parts = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag.lower() == "a" and attrs.get("href"):
            self.links.append((attrs["href"].strip(), attrs.get("title", "")))
        elif tag.lower() == "title":
            self._in_title = True

    def handle_endtag(self, tag):
        if tag.lower() == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title_parts.append(data.strip())


def fetch(url, method="GET", max_bytes=None):
    """Fetch a URL with retries, HTTPS validation, and a bounded page size."""
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "*/*",
    }
    request = urllib.request.Request(url, headers=headers, method=method)
    last_error = None
    for attempt in range(RETRIES + 1):
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                final_url = response.geturl()
                content_type = response.headers.get("Content-Type", "")
                length = response.headers.get("Content-Length")
                if max_bytes and length and int(length) > max_bytes:
                    raise ValueError(f"response too large ({length} bytes)")
                data = response.read(max_bytes + 1 if max_bytes else -1)
                if max_bytes and len(data) > max_bytes:
                    raise ValueError(f"response exceeded {max_bytes} bytes")
                return final_url, content_type, data, dict(response.headers.items())
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
            last_error = exc
            if attempt < RETRIES:
                time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"request failed: {last_error}")


def page_links(url):
    """Return resolved links from an HTML page; errors are logged and skipped."""
    try:
        final_url, content_type, data, _ = fetch(url, max_bytes=MAX_PAGE_BYTES)
        if "html" not in content_type.lower() and not data.lstrip().startswith(b"<"):
            return []
        # Most current pages declare UTF-8; replacement avoids a broken page stopping the run.
        text = data.decode("utf-8", errors="replace")
        parser = LinkParser()
        parser.feed(text)
        result = []
        for href, title in parser.links:
            absolute = urllib.parse.urljoin(final_url, html.unescape(href))
            parts = urllib.parse.urlsplit(absolute)
            if parts.scheme not in {"http", "https"}:
                continue
            result.append((absolute, title))
        return result
    except Exception as exc:
        log("WARN", f"Could not parse {url}: {exc}")
        return []


def normalize_category(url):
    """Return the first path segment as a coarse category label."""
    segments = [segment for segment in urllib.parse.urlsplit(url).path.split("/") if segment]
    return segments[0] if segments else "uncategorized"


def is_oreilly_url(url):
    """Restrict page discovery to O'Reilly's official web domains."""
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    return host == "oreilly.com" or host.endswith(".oreilly.com")


def discover_pages(start_url, max_pages):
    """Breadth-first discovery of accessible O'Reilly pages from the start page."""
    queue = [start_url]
    seen = set()
    pages = []
    while queue and len(seen) < max_pages:
        url = queue.pop(0)
        if url in seen:
            continue
        seen.add(url)
        log("SCAN", url)
        links = page_links(url)
        pages.append(url)
        for link, _ in links:
            parts = urllib.parse.urlsplit(link)
            path = parts.path.lower()
            # Focus on likely free-book pages and avoid crawling the whole domain.
            likely_page = (
                "/free/" in path
                or path.endswith(".csp")
                or "/library/view/" in path
            )
            if is_oreilly_url(link) and likely_page and link not in seen and link not in queue:
                queue.append(link)
        # Keep a small pause between page requests.
        time.sleep(0.25)
    return pages


def direct_file_url(url):
    """Recognize direct ebook file URLs and reject obvious non-book assets."""
    path = urllib.parse.urlsplit(url).path.lower()
    suffix = Path(path).suffix
    return suffix in ALLOWED_EXTENSIONS and suffix not in SKIP_EXTENSIONS


def safe_filename(url, title=""):
    """Create a filesystem-safe filename from the URL or supplied link title."""
    path_name = urllib.parse.unquote(Path(urllib.parse.urlsplit(url).path).name)
    name = path_name or title or "ebook"
    name = re.sub(r'[\\x00-\\x1f<>:"/\\\\|?*]+', "_", name).strip(" .")
    if not Path(name).suffix.lower() in ALLOWED_EXTENSIONS:
        name += ".ebook"
    return name[:180] or "ebook.ebook"


def download_stream(url, outdir, overwrite=False):
    """Stream a direct file to disk so large downloads do not exhaust phone RAM."""
    name = safe_filename(url)
    target = outdir / name
    if target.exists() and not overwrite and target.stat().st_size > 0:
        log("SKIP", f"already exists: {target}")
        return "skip"
    temporary = target.with_suffix(target.suffix + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(RETRIES + 1):
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                final_url = response.geturl()
                content_type = response.headers.get("Content-Type", "").lower()
                # Refuse HTML error/login pages masquerading as book downloads.
                if "text/html" in content_type:
                    raise ValueError("server returned HTML, not a direct ebook file")
                outdir.mkdir(parents=True, exist_ok=True)
                with temporary.open("wb") as handle:
                    while True:
                        chunk = response.read(64 * 1024)
                        if not chunk:
                            break
                        handle.write(chunk)
                if temporary.stat().st_size == 0:
                    raise ValueError("empty response")
                temporary.replace(target)
                log("SAVED", f"{target} ({target.stat().st_size} bytes)")
                return "saved"
        except Exception as exc:
            log("WARN", f"Attempt {attempt + 1}/{RETRIES + 1} failed for {url}: {exc}")
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
            if attempt < RETRIES:
                time.sleep(1.5 * (attempt + 1))
    return "error"


def collect_links(pages):
    """Collect unique direct ebook URLs from discovered pages."""
    found = {}
    for page in pages:
        for url, title in page_links(page):
            if direct_file_url(url):
                found.setdefault(url, title)
    return found


def main():
    """Parse options, discover links, optionally download, and save a URL manifest."""
    global ALLOWED_EXTENSIONS
    parser = argparse.ArgumentParser(
        description="Find publicly linked O'Reilly free ebook files; no login/form bypass."
    )
    parser.add_argument("--start-url", default=DEFAULT_START, help="Starting O'Reilly page")
    parser.add_argument("--out", default="ebooks-oreilly", help="Output directory")
    parser.add_argument("--types", nargs="+", default=["pdf", "epub", "mobi"],
                        help="File types to accept, e.g. pdf epub")
    parser.add_argument("--max-pages", type=int, default=40, help="Maximum pages to scan")
    parser.add_argument("--workers", type=int, default=2, help="Concurrent downloads (1-4 recommended)")
    parser.add_argument("--dry-run", action="store_true", help="List links without downloading")
    parser.add_argument("--overwrite", action="store_true", help="Replace existing files")
    parser.add_argument("--verbose", action="store_true", help="Print every discovered URL")
    args = parser.parse_args()

    # Enforce safe, small values on mobile and normalize requested extensions.
    args.max_pages = max(1, min(args.max_pages, 500))
    args.workers = max(1, min(args.workers, 4))
    allowed = {"." + item.lower().lstrip(".") for item in args.types}
    invalid = allowed - ALLOWED_EXTENSIONS
    if invalid:
        parser.error("unsupported file type(s): " + ", ".join(sorted(invalid)))
    ALLOWED_EXTENSIONS = allowed

    print(f"Username: {os.environ.get('USER') or os.environ.get('LOGNAME') or 'unknown'}")
    print(f"Python: {sys.version.split()[0]} | Output: {Path(args.out).expanduser().resolve()}")
    print("Mode: " + ("DRY RUN" if args.dry_run else "DOWNLOAD publicly linked files"))
    print("Note: O'Reilly's site may have changed; unavailable pages are skipped, not bypassed.")

    start = args.start_url
    if not is_oreilly_url(start):
        parser.error("--start-url must be an official oreilly.com URL")

    pages = discover_pages(start, args.max_pages)
    links = collect_links(pages)
    outdir = Path(args.out).expanduser().resolve()
    outdir.mkdir(parents=True, exist_ok=True)
    manifest = outdir / "urls.txt"
    with manifest.open("w", encoding="utf-8") as handle:
        for url in sorted(links):
            handle.write(url + "\n")

    log("INFO", f"Scanned {len(pages)} page(s); found {len(links)} direct ebook file link(s).")
    log("INFO", f"URL manifest: {manifest}")
    if args.verbose:
        for url in sorted(links):
            print(url)
    if args.dry_run:
        return 0

    counts = {"saved": 0, "skip": 0, "error": 0}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs = {
            pool.submit(download_stream, url, outdir, args.overwrite): url
            for url in sorted(links)
        }
        for job in concurrent.futures.as_completed(jobs):
            try:
                counts[job.result()] += 1
            except Exception as exc:
                counts["error"] += 1
                log("WARN", f"Unexpected worker error: {exc}")
    log("DONE", f"Saved {counts['saved']}; skipped {counts['skip']}; failed {counts['error']}.")
    return 0 if counts["error"] == 0 else 1


if __name__ == "__main__":
    # Keep unexpected failures readable and avoid dumping a full traceback by default.
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("STOP", "Interrupted by user.")
        raise SystemExit(130)
    except Exception as exc:
        log("ERROR", f"Fatal error: {exc}")
        raise SystemExit(1)
OREILLY_PYTHON_APP
fi

# Validate the script before exposing the launcher.
python3 -m py_compile "$PY_TARGET" || die "Python syntax check failed."
chmod 700 "$PY_TARGET"
cat > "${BIN_DIR}/oreilly-books" <<'LAUNCHER'
#!/usr/bin/env bash
# Launch the O'Reilly tool from any working directory.
set -Eeuo pipefail
exec python3 "${HOME}/oreilly-books/oreilly_3.py" "$@"
LAUNCHER
chmod 700 "${BIN_DIR}/oreilly-books"

# Install a copy of this installer for future updates if it was run from a file.
if [ -f "${SCRIPT_DIR}/${SCRIPT_NAME}" ]; then
    cp "${SCRIPT_DIR}/${SCRIPT_NAME}" "$SH_TARGET" || log "WARN: could not copy installer to ${SH_TARGET}"
    chmod 700 "$SH_TARGET" 2>/dev/null || true
fi

log "Install complete."
log "Username: ${CURRENT_USER} (not root)"
log "Program: ${PY_TARGET}"
log "Launcher: ${BIN_DIR}/oreilly-books"
log "Run a safe test: ${BIN_DIR}/oreilly-books --dry-run --verbose"
log "Run downloads: ${BIN_DIR}/oreilly-books --out \"\$HOME/ebooks-oreilly\""
