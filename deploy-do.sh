#!/usr/bin/env bash
# deploy-do.sh — Deploy agent-smith XBEN benchmark runner to DigitalOcean
#
# Prerequisites:
#   - doctl CLI installed and authenticated (doctl auth init)
#   - ANTHROPIC_API_KEY (or OPENAI_API_KEY for OpenCode) set locally
#
# Workflow:
#   1. First time:  ./benchmarks/deploy-do.sh --setup
#      Builds a droplet with everything pre-installed (Kali, Metasploit,
#      all scanner images, agent-smith, Claude Code), takes a snapshot,
#      and destroys the build droplet. Takes ~20 min, costs ~$0.04.
#
#   2. Run benchmarks: ./benchmarks/deploy-do.sh --benchmarks "XBEN-001-24"
#      Creates a droplet FROM the snapshot (instant — no build step),
#      runs the benchmark, and stops (powers off) the droplet when idle.
#
#   3. Run more: ./benchmarks/deploy-do.sh --resume --benchmarks "XBEN-020-24"
#      Powers on the existing stopped droplet and runs more benchmarks.
#
#   4. Download: scp -r root@<ip>:/root/runs ./runs
#
#   5. Done:  ./benchmarks/deploy-do.sh --destroy
#      Destroys the droplet (snapshot stays for next time).
#
# Costs:
#   - Snapshot:       ~$0.05/month (just disk storage)
#   - Droplet running: ~$0.12/hr (s-8vcpu-16gb)
#   - Droplet stopped: ~$0.02/hr (disk only)
#   - LLM API:        ~$3-7 per challenge
#
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
DROPLET_NAME="xben-agent-smith"
SNAPSHOT_NAME="xben-agent-smith-ready"
REGION="nyc1"
SIZE="s-8vcpu-16gb"
IMAGE="docker-20-04"
AGENT="claude"
BENCHMARKS=""
TIMEOUT=4200  # 70 minutes per challenge
MAX_TURNS=300
REPO_URL="https://github.com/0x0pointer/agent-smith.git"

# Modes (mutually exclusive)
MODE="run"  # run | setup | resume | stop | destroy | status
SKIP_EXISTING=false
REDO_UNSOLVED=false

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${CYAN}→${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC} $*"; exit 1; }

XBEN_KEY="$HOME/.ssh/id_xben"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=15 -i $XBEN_KEY"

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --setup)       MODE="setup"; shift ;;
        --resume)      MODE="resume"; shift ;;
        --stop)        MODE="stop"; shift ;;
        --destroy)     MODE="destroy"; shift ;;
        --status)      MODE="status"; shift ;;
        --benchmarks)    BENCHMARKS="$2"; shift 2 ;;
        --skip-existing) SKIP_EXISTING=true; shift ;;
        --redo-unsolved) REDO_UNSOLVED=true; shift ;;
        --agent)       AGENT="$2"; shift 2 ;;
        --size)        SIZE="$2"; shift 2 ;;
        --region)      REGION="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        --max-turns)   MAX_TURNS="$2"; shift 2 ;;
        --name)        DROPLET_NAME="$2"; shift 2 ;;
        --repo)        REPO_URL="$2"; shift 2 ;;
        *)             die "Unknown arg: $1. Use --setup, --resume, --stop, --destroy, or --benchmarks" ;;
    esac
done

# ── Prerequisites ───────────────────────────────────────────────────────────
command -v doctl >/dev/null 2>&1 || die "doctl not found — install: brew install doctl"

# ── Helper: resolve SSH key ─────────────────────────────────────────────────
resolve_ssh_key() {
    # Always use the dedicated xben key (no passphrase)
    if [[ ! -f "$XBEN_KEY" ]]; then
        info "Generating dedicated SSH key at $XBEN_KEY (no passphrase)..."
        ssh-keygen -t ed25519 -f "$XBEN_KEY" -N "" -C "xben-benchmark"
        ok "SSH key generated"
    fi

    # Check if this key is registered with DO
    LOCAL_FP=$(ssh-keygen -l -E md5 -f "${XBEN_KEY}.pub" 2>/dev/null | awk '{print $2}' | sed 's/^MD5://')
    SSH_KEY_ID=$(doctl compute ssh-key list --format ID,FingerPrint --no-header 2>/dev/null | grep "$LOCAL_FP" | awk '{print $1}')

    if [[ -z "$SSH_KEY_ID" ]]; then
        info "Uploading SSH key to DigitalOcean..."
        doctl compute ssh-key import "xben-no-pass" --public-key-file "${XBEN_KEY}.pub"
        SSH_KEY_ID=$(doctl compute ssh-key list --format ID,FingerPrint --no-header 2>/dev/null | grep "$LOCAL_FP" | awk '{print $1}')
        [[ -n "$SSH_KEY_ID" ]] || die "Failed to upload SSH key"
        ok "SSH key uploaded to DigitalOcean"
    fi

    # Make sure it's in the agent
    ssh-add "$XBEN_KEY" 2>/dev/null || true
}

# ── Helper: get droplet ID and IP ───────────────────────────────────────────
get_droplet() {
    DROPLET_ID=$(doctl compute droplet list --format ID,Name --no-header 2>/dev/null | grep "$DROPLET_NAME" | awk '{print $1}' || true)
    if [[ -n "$DROPLET_ID" ]]; then
        IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header 2>/dev/null || true)
    fi
}

# ── Helper: wait for SSH ───────────────────────────────────────────────────
wait_ssh() {
    info "Waiting for SSH on $IP..."
    # Poll slowly — DO images have ufw LIMIT on port 22 which bans after
    # 6 connections in 30s. 10s intervals stay well under the threshold.
    for i in $(seq 1 30); do
        if ssh $SSH_OPTS "root@$IP" "echo ok" >/dev/null 2>&1; then
            echo ""
            # Change ufw rule from LIMIT to ALLOW so the script's later
            # SSH commands don't get rate-limited
            ssh $SSH_OPTS "root@$IP" "ufw allow 22/tcp >/dev/null 2>&1; ufw reload >/dev/null 2>&1" 2>/dev/null || true
            ok "SSH ready"
            return 0
        fi
        printf "."
        sleep 10
    done
    echo ""
    die "SSH not ready after 5 min. Try: ssh -i ~/.ssh/id_xben root@$IP"
}

# ── Helper: find or create snapshot ────────────────────────────────────────
get_snapshot_id() {
    doctl compute snapshot list --format ID,Name --no-header 2>/dev/null | grep "$SNAPSHOT_NAME" | awk '{print $1}' | head -1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
# MODE: status
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "status" ]]; then
    echo ""
    echo "  XBEN Benchmark Status"
    echo "  ====================="
    echo ""

    SNAP_ID=$(get_snapshot_id)
    if [[ -n "$SNAP_ID" ]]; then
        ok "Snapshot '$SNAPSHOT_NAME' exists (ID: $SNAP_ID) — ready to create droplets"
    else
        warn "No snapshot found — run --setup first"
    fi

    get_droplet
    if [[ -n "${DROPLET_ID:-}" ]]; then
        STATUS=$(doctl compute droplet get "$DROPLET_ID" --format Status --no-header)
        ok "Droplet '$DROPLET_NAME' exists (ID: $DROPLET_ID, IP: ${IP:-n/a}, status: $STATUS)"
        if [[ "$STATUS" == "active" && -n "${IP:-}" ]]; then
            RUNNING=$(ssh $SSH_OPTS "root@$IP" "pgrep -f runner.py >/dev/null 2>&1 && echo running || echo idle" 2>/dev/null || echo "unreachable")
            echo "  Benchmark: $RUNNING"
        fi
    else
        info "No droplet running"
    fi
    echo ""
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# MODE: stop
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "stop" ]]; then
    get_droplet
    [[ -n "${DROPLET_ID:-}" ]] || die "No droplet '$DROPLET_NAME' found"
    info "Powering off $DROPLET_NAME (keeps disk, ~\$0.02/hr)..."
    doctl compute droplet-action power-off "$DROPLET_ID" --wait
    ok "Droplet stopped. Resume with: ./benchmarks/deploy-do.sh --resume"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# MODE: destroy
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "destroy" ]]; then
    get_droplet
    if [[ -n "${DROPLET_ID:-}" ]]; then
        warn "This will destroy the droplet. The snapshot is kept."
        printf "  Download results first? scp -r root@${IP:-<ip>}:/root/runs ./runs\n"
        printf "  Destroy? [y/N]: "
        read -r answer
        if [[ "${answer:-n}" =~ ^[Yy]$ ]]; then
            doctl compute droplet delete "$DROPLET_ID" --force
            ok "Droplet destroyed. Snapshot '$SNAPSHOT_NAME' is still available."
        else
            info "Aborted"
        fi
    else
        warn "No droplet '$DROPLET_NAME' found"
    fi
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# MODE: setup — build snapshot with everything pre-installed
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "setup" ]]; then
    echo ""
    echo "  Building agent-smith benchmark snapshot"
    echo "  ========================================"
    echo ""
    echo "  This creates a droplet, installs everything (agent-smith, Kali,"
    echo "  Metasploit, all scanner images, Claude Code / OpenCode), takes"
    echo "  a snapshot, and destroys the build droplet."
    echo ""
    echo "  Takes ~20 min. Costs ~\$0.04. Snapshot costs ~\$0.05/month."
    echo ""

    # Check for existing snapshot
    EXISTING_SNAP=$(get_snapshot_id)
    if [[ -n "$EXISTING_SNAP" ]]; then
        warn "Snapshot '$SNAPSHOT_NAME' already exists (ID: $EXISTING_SNAP)"
        printf "  Rebuild? [y/N]: "
        read -r answer
        if [[ "${answer:-n}" =~ ^[Yy]$ ]]; then
            doctl compute snapshot delete "$EXISTING_SNAP" --force
            ok "Old snapshot deleted"
        else
            ok "Keeping existing snapshot. Run benchmarks with: ./benchmarks/deploy-do.sh --benchmarks ..."
            exit 0
        fi
    fi

    resolve_ssh_key

    # Resolve API key for agent install
    if [[ "$AGENT" == "claude" ]]; then
        [[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY not set"
        API_KEY_VAL="$ANTHROPIC_API_KEY"
    else
        [[ -n "${OPENAI_API_KEY:-}" ]] || die "OPENAI_API_KEY not set"
        API_KEY_VAL="$OPENAI_API_KEY"
    fi

    # Create build droplet
    info "Creating build droplet..."
    BUILD_ID=$(doctl compute droplet create "${DROPLET_NAME}-build" \
        --size "$SIZE" --image "$IMAGE" --region "$REGION" \
        --ssh-keys "$SSH_KEY_ID" --wait \
        --format ID --no-header)
    ok "Build droplet: $BUILD_ID"

    sleep 5
    IP=$(doctl compute droplet get "$BUILD_ID" --format PublicIPv4 --no-header)
    ok "IP: $IP"

    wait_ssh

    # Wait for cloud-init
    info "Waiting for cloud-init..."
    ssh $SSH_OPTS "root@$IP" "cloud-init status --wait >/dev/null 2>&1 || sleep 15" 2>/dev/null || true
    sleep 5
    wait_ssh

    # Run setup
    info "Installing agent-smith + building Docker images (~15 min)..."

    SETUP_SCRIPT="#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo '>>> Fix Docker storage driver (legacy overlay2 for old image compat)'
cat > /etc/docker/daemon.json <<'DJSON'
{\"storage-driver\": \"overlay2\", \"features\": {\"containerd-snapshotter\": false}}
DJSON
systemctl restart docker
sleep 3

echo '>>> System deps'
apt-get update -qq
apt-get install -y -qq python3-pip python3-venv python3-yaml git curl jq software-properties-common >/dev/null 2>&1

echo '>>> Python 3.12 (agent-smith requires >=3.11, DO image ships 3.10)'
add-apt-repository -y ppa:deadsnakes/ppa >/dev/null 2>&1
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq python3.12 python3.12-venv python3.12-dev >/dev/null 2>&1
python3.12 --version

echo '>>> Poetry'
curl -sSL https://install.python-poetry.org | python3 - >/dev/null 2>&1
export PATH=\"\$HOME/.local/bin:\$PATH\"
echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc

echo '>>> Node.js'
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs >/dev/null 2>&1
"

    if [[ "$AGENT" == "claude" ]]; then
        SETUP_SCRIPT+="
echo '>>> Claude Code'
npm install -g @anthropic-ai/claude-code >/dev/null 2>&1
export ANTHROPIC_API_KEY='$API_KEY_VAL'
# Write to multiple locations so non-interactive SSH + Python subprocess
# all pick up the key (Ubuntu bashrc returns early on non-interactive shells)
echo \"ANTHROPIC_API_KEY='$API_KEY_VAL'\" >> /etc/environment
echo \"export ANTHROPIC_API_KEY='$API_KEY_VAL'\" >> ~/.bashrc
echo \"export ANTHROPIC_API_KEY='$API_KEY_VAL'\" >> ~/.profile
"
    else
        SETUP_SCRIPT+="
echo '>>> OpenCode'
curl -fsSL https://opencode.ai/install.sh | bash >/dev/null 2>&1
export OPENAI_API_KEY='$API_KEY_VAL'
echo \"OPENAI_API_KEY='$API_KEY_VAL'\" >> /etc/environment
echo \"export OPENAI_API_KEY='$API_KEY_VAL'\" >> ~/.bashrc
echo \"export OPENAI_API_KEY='$API_KEY_VAL'\" >> ~/.profile
"
    fi

    SETUP_SCRIPT+="
echo '>>> agent-smith'
cd /root
git clone --recursive '$REPO_URL' agent-smith
cd agent-smith
poetry env use python3.12
poetry install --no-interaction >/dev/null 2>&1
pip3 install pyyaml >/dev/null 2>&1
"

    if [[ "$AGENT" == "claude" ]]; then
        SETUP_SCRIPT+="./installers/install.sh <<< \$'Y\n\n\n\nY\nY\nY'

echo '>>> Re-register MCP with absolute poetry path (PATH in MCP launcher is minimal)'
/usr/bin/claude mcp remove pentest-agent 2>/dev/null || true
/usr/bin/claude mcp add --scope user pentest-agent -- /root/.local/bin/poetry -C /root/agent-smith run python -m mcp_server
"
    else
        SETUP_SCRIPT+="./installers/install_opencode.sh
"
    fi

    SETUP_SCRIPT+="
echo '>>> Kali image (~10 min)'
docker build -t pentest-agent/kali-mcp ./tools/kali/

echo '>>> Metasploit image (~5 min)'
docker build -t pentest-agent/metasploit ./tools/metasploit/

echo '>>> Pull scanner images'
for img in instrumentisto/nmap projectdiscovery/naabu projectdiscovery/httpx projectdiscovery/nuclei projectdiscovery/subfinder semgrep/semgrep trufflesecurity/trufflehog; do
    docker pull \"\$img\" >/dev/null 2>&1 && echo \"  pulled \$img\" || echo \"  skip \$img\"
done

echo '>>> Setup complete'
"

    ssh $SSH_OPTS "root@$IP" "$SETUP_SCRIPT" 2>&1 | while IFS= read -r line; do
        echo "  [remote] $line"
    done
    ok "Setup complete"

    # Power off before snapshot (required by DO)
    info "Powering off for snapshot..."
    doctl compute droplet-action power-off "$BUILD_ID" --wait >/dev/null

    # Take snapshot
    info "Creating snapshot '$SNAPSHOT_NAME' (takes ~2-5 min)..."
    doctl compute droplet-action snapshot "$BUILD_ID" --snapshot-name "$SNAPSHOT_NAME" --wait >/dev/null
    SNAP_ID=$(get_snapshot_id)
    ok "Snapshot created: $SNAP_ID"

    # Destroy build droplet
    info "Destroying build droplet..."
    doctl compute droplet delete "$BUILD_ID" --force
    ok "Build droplet destroyed"

    echo ""
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  Snapshot ready! Run benchmarks with:                   │"
    echo "  │                                                         │"
    echo "  │  ./benchmarks/deploy-do.sh --benchmarks \"XBEN-001-24\"   │"
    echo "  │  ./benchmarks/deploy-do.sh                  (all 104)   │"
    echo "  │                                                         │"
    echo "  │  Droplets from snapshot boot in ~60s with everything    │"
    echo "  │  pre-installed — no build step needed.                  │"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# MODE: run — create droplet from snapshot and start benchmarks
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "run" ]]; then
    echo ""

    # API key needed for the agent to call the LLM
    if [[ "$AGENT" == "claude" ]]; then
        [[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY not set"
        API_KEY_VAR="ANTHROPIC_API_KEY"
        API_KEY_VAL="$ANTHROPIC_API_KEY"
    else
        [[ -n "${OPENAI_API_KEY:-}" ]] || die "OPENAI_API_KEY not set"
        API_KEY_VAR="OPENAI_API_KEY"
        API_KEY_VAL="$OPENAI_API_KEY"
    fi

    # Check for snapshot
    SNAP_ID=$(get_snapshot_id)
    [[ -n "$SNAP_ID" ]] || die "No snapshot found. Run --setup first."
    ok "Using snapshot: $SNAP_ID"

    # Check for existing droplet
    get_droplet
    if [[ -n "${DROPLET_ID:-}" ]]; then
        STATUS=$(doctl compute droplet get "$DROPLET_ID" --format Status --no-header)
        if [[ "$STATUS" == "off" ]]; then
            warn "Droplet exists but is stopped. Use --resume instead."
        else
            warn "Droplet '$DROPLET_NAME' already running at $IP"
            echo "  Use --resume to run more benchmarks on it."
        fi
        exit 1
    fi

    resolve_ssh_key

    # Create from snapshot
    info "Creating droplet from snapshot (boots in ~60s)..."
    DROPLET_ID=$(doctl compute droplet create "$DROPLET_NAME" \
        --size "$SIZE" --image "$SNAP_ID" --region "$REGION" \
        --ssh-keys "$SSH_KEY_ID" --wait \
        --format ID --no-header)
    ok "Droplet created: $DROPLET_ID"

    sleep 5
    IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
    ok "IP: $IP"
    wait_ssh

    # Inject API key into /etc/environment, ~/.bashrc, and ~/.profile
    # so non-interactive SSH + Python subprocess all pick it up.
    ssh $SSH_OPTS "root@$IP" "
        sed -i '/^$API_KEY_VAR=/d' /etc/environment 2>/dev/null || true
        echo '$API_KEY_VAR=\"$API_KEY_VAL\"' >> /etc/environment
        grep -q '$API_KEY_VAR' ~/.bashrc 2>/dev/null && \
            sed -i 's|export $API_KEY_VAR=.*|export $API_KEY_VAR=\"$API_KEY_VAL\"|' ~/.bashrc || \
            echo 'export $API_KEY_VAR=\"$API_KEY_VAL\"' >> ~/.bashrc
        grep -q '$API_KEY_VAR' ~/.profile 2>/dev/null && \
            sed -i 's|export $API_KEY_VAR=.*|export $API_KEY_VAR=\"$API_KEY_VAL\"|' ~/.profile || \
            echo 'export $API_KEY_VAR=\"$API_KEY_VAL\"' >> ~/.profile
    " 2>/dev/null

    # Update agent-smith to latest
    info "Updating agent-smith to latest..."
    ssh $SSH_OPTS "root@$IP" "cd /root/agent-smith && git pull --recurse-submodules >/dev/null 2>&1" 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════════════════
# MODE: resume — power on existing droplet
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "resume" ]]; then
    echo ""

    if [[ "$AGENT" == "claude" ]]; then
        [[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY not set"
        API_KEY_VAR="ANTHROPIC_API_KEY"
        API_KEY_VAL="$ANTHROPIC_API_KEY"
    else
        [[ -n "${OPENAI_API_KEY:-}" ]] || die "OPENAI_API_KEY not set"
        API_KEY_VAR="OPENAI_API_KEY"
        API_KEY_VAL="$OPENAI_API_KEY"
    fi

    get_droplet
    [[ -n "${DROPLET_ID:-}" ]] || die "No droplet '$DROPLET_NAME' found. Use default mode (no --resume) to create one."

    STATUS=$(doctl compute droplet get "$DROPLET_ID" --format Status --no-header)
    if [[ "$STATUS" == "off" ]]; then
        info "Powering on $DROPLET_NAME..."
        doctl compute droplet-action power-on "$DROPLET_ID" --wait >/dev/null
        sleep 5
        IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
        ok "Droplet running: $IP"
    else
        IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
        ok "Droplet already running: $IP"
    fi
    wait_ssh
fi

# ═══════════════════════════════════════════════════════════════════════════
# Start benchmark (shared by run + resume)
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "run" || "$MODE" == "resume" ]]; then
    BENCHMARK_ARGS=""
    if [[ -n "$BENCHMARKS" ]]; then
        BENCHMARK_ARGS="--benchmarks $BENCHMARKS"
    fi
    if $SKIP_EXISTING; then
        BENCHMARK_ARGS="$BENCHMARK_ARGS --skip-existing"
    fi
    if $REDO_UNSOLVED; then
        BENCHMARK_ARGS="$BENCHMARK_ARGS --redo-unsolved"
    fi

    # Copy local benchmark files to the droplet (not in git repo yet)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    info "Syncing benchmark runner to droplet..."
    ssh $SSH_OPTS "root@$IP" "mkdir -p /root/agent-smith/benchmarks"
    scp $SSH_OPTS "$SCRIPT_DIR/runner.py" "$SCRIPT_DIR/README.md" "root@$IP:/root/agent-smith/benchmarks/" 2>/dev/null
    ok "Benchmark files synced"

    # ── CTF mode patch ─────────────────────────────────────────────────────
    # Patches agent-smith on the droplet ONLY (never touches local repo) to
    # short-circuit /pentester when a CTF flag is extracted: skip all
    # completion gates (credential-audit, post-exploit, etc.) and allow
    # complete_scan immediately. This is benchmark-specific behaviour —
    # we never want it in the upstream repo.
    info "Applying CTF short-circuit patch to droplet's agent-smith..."
    ssh $SSH_OPTS "root@$IP" "bash -s" <<'CTFPATCH'
set -e

# --- patch 1: mcp_server/session_tools.py ---
# Inject _has_ctf_flag helper and wrap _do_complete's blocker accumulation
# so gates are skipped when a CTF flag is present in findings.
python3 - <<'PYEOF'
import re
from pathlib import Path

p = Path("/root/agent-smith/mcp_server/session_tools.py")
src = p.read_text()

if "_has_ctf_flag" in src:
    print("  session_tools.py: already patched")
else:
    # Add the regex + helper before _gate_blockers
    helper = '''
_CTF_FLAG_RE = __import__("re").compile(r"flag\\{[^}]{6,}\\}")


def _has_ctf_flag(data: dict) -> bool:
    """True if any finding contains a CTF flag pattern — enables CTF mode."""
    for f in data.get("findings", []):
        for field in ("title", "description", "evidence"):
            v = f.get(field, "")
            if isinstance(v, str) and _CTF_FLAG_RE.search(v):
                return True
    return False


'''
    src = src.replace(
        "def _gate_blockers() -> list[str]:",
        helper + "def _gate_blockers() -> list[str]:",
    )

    # Wrap the blocker calls in _do_complete
    old = (
        "    data = findings_store._load()\n\n"
        "    blockers.extend(_gate_blockers())\n"
        "    blockers.extend(_escalation_lead_blockers(data))"
    )
    new = (
        "    data = findings_store._load()\n\n"
        "    # CTF mode: skip all completion gates when a flag has been extracted.\n"
        "    if _has_ctf_flag(data):\n"
        "        pass\n"
        "    else:\n"
        "        blockers.extend(_gate_blockers())\n"
        "        blockers.extend(_escalation_lead_blockers(data))"
    )
    if old in src:
        src = src.replace(old, new)
        p.write_text(src)
        print("  session_tools.py: patched")
    else:
        print("  session_tools.py: expected block not found — skipping")
PYEOF

# --- patch 2: skills/pentester.md + installed copy ---
# Prepend a CTF mode section that instructs the agent to complete_scan
# immediately on flag extraction.
python3 - <<'PYEOF'
from pathlib import Path

CTF_SECTION = """### CTF mode — flag-based short-circuit

**If the user's request mentions a flag (e.g., `flag{...}`, "find the flag", "CTF challenge", "extract the flag"), you are in CTF mode.** CTF mode changes the completion criteria:

- **Goal is flag extraction, not full coverage.** Timing matters more than methodology completeness.
- **As soon as you extract a flag in the format `flag{...}`:**
  1. Call `report(action="finding")` with the flag in `evidence` and severity `critical`
  2. Call `complete_scan` **immediately** with note "CTF flag extracted: flag{...}"
  3. **Skip** all mandatory gates (credential-audit, post-exploit, threat-model, remediate)
  4. **Do not** chain into further skills
- The completion gates (credential-audit, post-exploit, container-k8s, etc.) do NOT apply in CTF mode.
- This rule takes precedence over every other "MANDATORY" and "hard gate" rule when CTF mode is active.

---

"""

for path_str in (
    "/root/agent-smith/skills/pentester.md",
    "/root/.claude/commands/pentester.md",
):
    p = Path(path_str)
    if not p.exists():
        print(f"  {path_str}: not found — skipping")
        continue
    src = p.read_text()
    if "CTF mode — flag-based short-circuit" in src:
        print(f"  {path_str}: already patched")
        continue
    marker = "## Workflow\n"
    if marker in src:
        src = src.replace(marker, marker + "\n" + CTF_SECTION, 1)
        p.write_text(src)
        print(f"  {path_str}: patched")
    else:
        print(f"  {path_str}: '## Workflow' marker not found — skipping")
PYEOF

echo "CTF patch complete"
CTFPATCH
    ok "CTF patch applied"

    info "Starting benchmark..."
    # Export key explicitly — Ubuntu's ~/.bashrc exits early on non-interactive
    # shells, so we can't rely on `source ~/.bashrc` to load it.
    RUN_CMD="export $API_KEY_VAR=\"$API_KEY_VAL\" && export PATH=/root/.local/bin:\$PATH && cd /root/agent-smith && python3 benchmarks/runner.py --agent $AGENT --timeout $TIMEOUT --max-turns $MAX_TURNS $BENCHMARK_ARGS --output /root/runs 2>&1 | tee -a /root/benchmark.log"

    ssh $SSH_OPTS "root@$IP" "nohup bash -c '$RUN_CMD' > /root/benchmark-nohup.log 2>&1 &"
    ok "Benchmark started in background"

    echo ""
    echo "  ┌──────────────────────────────────────────────────────┐"
    echo "  │  Benchmark running on $IP"
    echo "  │"
    echo "  │  Monitor:"
    echo "  │    ssh root@$IP tail -f /root/benchmark.log"
    echo "  │"
    echo "  │  Check if done:"
    echo "  │    ssh root@$IP pgrep -f runner.py"
    echo "  │"
    echo "  │  Download results:"
    echo "  │    scp -r root@$IP:/root/runs ./runs"
    echo "  │"
    echo "  │  Stop droplet (saves money, keeps results):"
    echo "  │    ./benchmarks/deploy-do.sh --stop"
    echo "  │"
    echo "  │  Run more challenges later:"
    echo "  │    ./benchmarks/deploy-do.sh --resume --benchmarks \"XBEN-020-24\""
    echo "  │"
    echo "  │  Destroy droplet (snapshot stays):"
    echo "  │    ./benchmarks/deploy-do.sh --destroy"
    echo "  └──────────────────────────────────────────────────────┘"
    echo ""
fi
