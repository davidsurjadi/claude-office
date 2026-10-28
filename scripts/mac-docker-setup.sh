#!/bin/bash
# One-command macOS setup: run the visualizer in Docker and wire the host
# Claude Code hooks to it, so local sessions in the Claude desktop app's
# Code tab (and the CLI) appear in the office at http://localhost:8050.
#
# Usage (from the repo root):
#   ./scripts/mac-docker-setup.sh              # install / update and start
#   ./scripts/mac-docker-setup.sh --uninstall  # remove hooks and stop the container
#
# Safe to re-run: every step is idempotent.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$HOME/.claude/claude-office-config.env"
SETTINGS_FILE="$HOME/.claude/settings.json"
UI_URL="http://localhost:8050"
EVENTS_URL="$UI_URL/api/v1/events"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '\nError: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "this script is for macOS only."

export PATH="$HOME/.local/bin:$PATH"

if [ "${1:-}" = "--uninstall" ]; then
    step "Removing Claude Office hooks from $SETTINGS_FILE"
    if command -v uv >/dev/null 2>&1; then
        uv run -p 3.14 "$REPO_DIR/hooks/manage_hooks.py" uninstall --hook-cmd claude-office-hook
    fi
    step "Stopping the container"
    (cd "$REPO_DIR" && docker compose down) || true
    echo "Done. Quit and reopen the Claude desktop app to apply."
    exit 0
fi

step "Checking Docker"
if ! command -v docker >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "Docker not found. Installing Docker Desktop with Homebrew..."
        brew install --cask docker
    else
        fail "Docker Desktop is not installed. Get it from https://www.docker.com/products/docker-desktop/ then re-run."
    fi
fi
if ! docker info >/dev/null 2>&1; then
    echo "Starting Docker Desktop..."
    open -a Docker
    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && break
        sleep 2
    done
    docker info >/dev/null 2>&1 || fail "Docker Desktop did not start. Open it once, accept its prompts, then re-run."
fi
echo "Docker is running."

step "Checking uv (runs the hooks)"
if ! command -v uv >/dev/null 2>&1; then
    echo "uv not found. Installing it to ~/.local/bin..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
command -v uv >/dev/null 2>&1 || fail "uv install failed. See https://docs.astral.sh/uv/ then re-run."
echo "uv $(uv --version | awk '{print $2}') ready."

step "Installing the Claude Code hooks"
# Pre-seed the API key with openssl so install.sh does not need a system
# python3 (which on a fresh Mac triggers the Xcode tools prompt). install.sh
# never replaces an existing key.
mkdir -p "$HOME/.claude"
if ! grep -q '^CLAUDE_OFFICE_API_KEY=.' "$CONFIG_FILE" 2>/dev/null; then
    printf 'CLAUDE_OFFICE_API_KEY=%s\n' "$(openssl rand -hex 32)" >> "$CONFIG_FILE"
fi
bash "$REPO_DIR/hooks/install.sh"

# Apps launched from the Dock do not inherit the shell PATH, so the bare
# "claude-office-hook" command would silently fail inside the desktop app.
# Re-register the hooks with the absolute path instead.
HOOK_PATH="$(command -v claude-office-hook || true)"
[ -n "$HOOK_PATH" ] || HOOK_PATH="$HOME/.local/bin/claude-office-hook"
[ -x "$HOOK_PATH" ] || fail "claude-office-hook was not installed at $HOOK_PATH."
uv run -p 3.14 "$REPO_DIR/hooks/manage_hooks.py" uninstall --hook-cmd "$HOOK_PATH" >/dev/null
uv run -p 3.14 "$REPO_DIR/hooks/manage_hooks.py" install --hook-cmd "$HOOK_PATH" >/dev/null
echo "Hooks registered with absolute path: $HOOK_PATH"

step "Pointing the hooks at the Docker port"
if grep -q '^CLAUDE_OFFICE_API_URL=' "$CONFIG_FILE"; then
    sed -i '' "s|^CLAUDE_OFFICE_API_URL=.*|CLAUDE_OFFICE_API_URL=$EVENTS_URL|" "$CONFIG_FILE"
else
    printf 'CLAUDE_OFFICE_API_URL=%s\n' "$EVENTS_URL" >> "$CONFIG_FILE"
fi
echo "CLAUDE_OFFICE_API_URL=$EVENTS_URL"

step "Building and starting the container (first build takes a few minutes)"
(cd "$REPO_DIR" && docker compose up -d --build)

step "Waiting for the backend"
for _ in $(seq 1 60); do
    curl -fsS "$UI_URL/health" >/dev/null 2>&1 && break
    sleep 2
done
curl -fsS "$UI_URL/health" >/dev/null 2>&1 || fail "backend not healthy. Check: docker compose logs claude-office"
echo "Backend is healthy."

open "$UI_URL"

cat <<EOF

Setup complete. The office is open at $UI_URL.

Next:
  1. Quit the Claude desktop app fully (Cmd+Q) and reopen it.
  2. Start a LOCAL session in the Code tab and send any prompt.
  3. Watch the boss appear in the browser tab.

The container restarts automatically whenever Docker Desktop is running.
To remove everything: ./scripts/mac-docker-setup.sh --uninstall
EOF
