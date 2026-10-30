#!/bin/sh
# Emit a line whenever GNOME interface settings change.
# Vim re-reads the current color scheme; it does not trust this output's contents.

if ! command -v gsettings >/dev/null 2>&1; then
    echo "gsettings is required" >&2
    exit 127
fi

exec gsettings monitor org.gnome.desktop.interface
