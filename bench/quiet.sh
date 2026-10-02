#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1
if [ -z "${PYTHON:-}" ]; then
    if command -v uv >/dev/null 2>&1; then
        PYTHON=$(uv python find --offline 3.13 2>/dev/null || command -v python3)
    else
        PYTHON=$(command -v python3)
    fi
fi
exec "$PYTHON" "$(dirname "$0")/quiet.py" "$@"
