# O'Reilly free ebook link tool

This is a modern, standard-library-only rewrite inspired by the two legacy scripts in the linked Gist.

## Important limitations

- It finds direct PDF/EPUB/MOBI links publicly present in accessible pages.
- It does not submit fake newsletter forms, bypass authentication, or defeat access controls.
- O'Reilly's current website may no longer expose the old free-ebook URLs. A zero-link result can mean the site changed, not that Python is broken.
- TLS certificate validation remains enabled. Do not disable certificate checks to hide network or certificate problems.
- No installer can guarantee that every remote site or network request will succeed. Failures are logged and retried.

## Install

Place `install.oreilly.books.sh` and `oreilly_3.py` in the same directory, then run:

```sh
chmod +x install.oreilly.books.sh
./install.oreilly.books.sh
```

The installer refuses to run as root and prints the account name. It supports Termux and Debian/Ubuntu. The Python program needs no third-party Python packages.

## Use

```sh
# Test discovery without downloading.
~/bin/oreilly-books --dry-run --verbose

# Download directly linked files to a directory.
~/bin/oreilly-books --out "$HOME/ebooks-oreilly"

# Scan more pages, with a small worker count.
~/bin/oreilly-books --max-pages 80 --workers 2 --out "$HOME/ebooks-oreilly"

# Only PDF files.
~/bin/oreilly-books --types pdf --dry-run
```

The tool writes `urls.txt` into the output directory and skips non-empty existing files unless `--overwrite` is supplied.
