#!/usr/bin/env bash
#
# conduit — README.md's Usage snippet, extracted from examples/usage.zig.
#
# A code snippet in a README is a claim about how the library is used, and
# nothing compiles it. This one is a region of an example that `zig build
# examples` builds AND runs, so the snippet a reader copies is code CI
# executes.
#
# Usage: ci/readme_usage.sh          # writes the fenced block to stdout
#        ci/readme_usage.sh --check  # exits non-zero if README.md has drifted

set -uo pipefail
cd "$(dirname "$0")/.."

block() {
python3 - <<'PY'
import pathlib
import sys

source = pathlib.Path("examples/usage.zig")
text = source.read_text(encoding="utf-8")

MARKER = "// --- README:usage ---"
parts = text.split(MARKER)
if len(parts) != 3:
    sys.exit(
        "%s: expected exactly two %s markers, found %d"
        % (source, MARKER, len(parts) - 1)
    )

# The import is the one line a reader needs that cannot live inside main, so it
# is read from the file too rather than written out here.
imports = [
    line for line in text.splitlines() if line.startswith('const conduit = @import(')
]
if len(imports) != 1:
    sys.exit("%s: expected exactly one `const conduit = @import(...)` line" % source)

body = []
for line in parts[1].splitlines():
    # The region sits inside main; the README shows it at the left margin.
    body.append(line[4:] if line.startswith("    ") else line)

print("```zig")
print(imports[0])
print()
print("\n".join(body).strip("\n"))
print("```")
PY
}

if [ "${1-}" = "--check" ]; then
    if ! block | python3 -c '
import pathlib, sys
want = sys.stdin.read()
readme = pathlib.Path("README.md").read_text(encoding="utf-8")
sys.exit(0 if want in readme else 1)
'; then
        echo "README.md: the Usage block no longer matches examples/usage.zig." >&2
        echo "Run ci/readme_usage.sh and paste the result into the Usage section." >&2
        exit 1
    fi
    exit 0
fi

block
