#!/usr/bin/env bash
# lint.sh -- Validate all infrastructure shell scripts
#
# Runs shellcheck on all .sh files and bash -n syntax checks on all .conf files.
# Exit non-zero if any check fails (suitable for CI gates).
#
# Usage:
#   ./lint.sh              # Lint all scripts
#   ./lint.sh --install    # Install shellcheck if missing, then lint

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
FAIL=0

err()  { echo "ERROR: $*" >&2; }
info() { echo "==> $*"; }
pass() { echo "  OK: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

# ---------------------------------------------------------------------------
# Install shellcheck if requested
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--install" ]]; then
    if ! command -v shellcheck &>/dev/null; then
        info "Installing shellcheck"
        apt-get update -qq && apt-get install -y --no-install-recommends shellcheck
    fi
fi

# ---------------------------------------------------------------------------
# Shellcheck: all .sh files
# ---------------------------------------------------------------------------

SHELLCHECK_AVAILABLE=1
if ! command -v shellcheck &>/dev/null; then
    SHELLCHECK_AVAILABLE=0
    info "shellcheck not found; falling back to syntax/custom checks only"
    info "Install with: apt-get install shellcheck (or ./lint.sh --install)"
fi

# Collect all .sh files
mapfile -t scripts < <(find "$REPO_ROOT" -name "*.sh" -not -path "*/.git/*" | sort)

for script in "${scripts[@]}"; do
    rel="${script#"$REPO_ROOT"/}"
    if [[ $SHELLCHECK_AVAILABLE -eq 1 ]]; then
        # SC1090: can't follow dynamic source (we use runtime source paths)
        # SC1091: can't follow sourced file (cross-directory sources)
        # SC2034: variable appears unused (inventory variables used by sourcing scripts)
        if shellcheck -x -S warning -e SC1090,SC1091,SC2034 "$script"; then
            pass "$rel"
        else
            fail "$rel"
        fi
    fi
done

info "Running bash -n syntax check on all .sh files"
for script in "${scripts[@]}"; do
    rel="${script#"$REPO_ROOT"/}"
    if bash -n "$script"; then
        pass "$rel"
    else
        fail "$rel"
    fi
done

# ---------------------------------------------------------------------------
# Bash syntax check: .conf files (sourced as bash)
# ---------------------------------------------------------------------------

info "Running bash -n syntax check on .conf files"

# Only check inventory.conf (bash-sourced). Other .conf files (HCL, INI) are not bash.
mapfile -t configs < <(find "$REPO_ROOT" -name "inventory.conf" -not -path "*/.git/*" | sort)

for config in "${configs[@]}"; do
    rel="${config#"$REPO_ROOT"/}"
    if bash -n "$config" 2>/dev/null; then
        pass "$rel"
    else
        fail "$rel"
    fi
done

# ---------------------------------------------------------------------------
# Custom checks
# ---------------------------------------------------------------------------

info "Running custom checks"

# Check for 'local' keyword outside function scope (bash error)
for script in "${scripts[@]}"; do
    rel="${script#"$REPO_ROOT"/}"
    local_hits="$(
        awk '
        function starts_fn(line) {
            return line ~ /^[[:space:]]*(function[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*$/
        }
        {
            line=$0
            if (!in_fn && starts_fn(line)) {
                in_fn=1
                depth=1
                next
            }

            if (!in_fn && line ~ /^[[:space:]]*local([[:space:]]|$)/) {
                print NR ":" line
            }

            if (in_fn) {
                opens = gsub(/\{/, "{", line)
                closes = gsub(/\}/, "}", line)
                depth += (opens - closes)
                if (depth <= 0) {
                    in_fn=0
                    depth=0
                }
            }
        }' "$script"
    )"
    if [[ -n "$local_hits" ]]; then
        fail "$rel: local used outside function scope"
        while IFS= read -r hit; do
            echo "  $rel:$hit" >&2
        done <<< "$local_hits"
    fi
done

# Check for em dashes (prohibited by style guide)
info "Checking for em dashes"
for script in "${scripts[@]}"; do
    rel="${script#"$REPO_ROOT"/}"
    if grep -Pn '\x{2014}' "$script" 2>/dev/null; then
        fail "$rel: contains em dash"
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
if [[ $FAIL -eq 0 ]]; then
    info "All checks passed (${#scripts[@]} scripts, ${#configs[@]} configs)"
else
    err "Some checks failed"
    exit 1
fi
