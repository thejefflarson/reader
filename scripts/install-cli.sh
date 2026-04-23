#!/bin/sh
# install-cli.sh — put the `reader` script somewhere on $PATH.
#
# Tries `/usr/local/bin` first (writable without sudo on most Intel
# /old-brew setups and on fresh machines where you've `mkdir`d it).
# Falls back to `~/.local/bin`, which you should already have on your
# PATH if you keep a local shell config.

set -e
cd "$(dirname "$0")/.."

SRC="$(pwd)/scripts/reader"
chmod +x "$SRC"

for dest in /usr/local/bin "$HOME/.local/bin"; do
    if [ -d "$dest" ] && [ -w "$dest" ]; then
        target="$dest/reader"
        ln -sf "$SRC" "$target"
        echo "linked $target → $SRC"
        echo ""
        echo "Run:  reader path/to/file.md"
        exit 0
    fi
done

echo "no writable install dir found (/usr/local/bin, ~/.local/bin)."
echo "Either make one writable, or copy scripts/reader somewhere on your PATH."
exit 1
