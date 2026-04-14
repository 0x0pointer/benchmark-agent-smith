#!/usr/bin/env bash
# fleet.sh — Parallel XBEN benchmark orchestrator for DigitalOcean
#
# Spawns N droplets from the xben-agent-smith-ready snapshot, splits the
# remaining benchmarks evenly across them, and kicks off benchmark runs
# on each one in parallel.
#
# Prerequisites:
#   - Snapshot already exists (run `./deploy-do.sh --setup` first)
#   - ANTHROPIC_API_KEY set locally
#   - ~/.ssh/id_xben SSH key exists and is uploaded to DO
#
# Usage:
#   ./fleet.sh launch 15              # 15 droplets, split remaining
#   ./fleet.sh launch 10 XBEN-003-24 XBEN-004-24 ...
#   ./fleet.sh status                 # show all fleet droplets
#   ./fleet.sh progress               # per-droplet solved/total
#   ./fleet.sh pull ./runs            # scp all results locally
#   ./fleet.sh destroy                # nuke all fleet droplets
#
set -euo pipefail

FLEET_PREFIX="xben-fleet"
SNAPSHOT_NAME="xben-agent-smith-ready"
SIZE="s-8vcpu-16gb"
REGION="nyc1"
XBEN_KEY="$HOME/.ssh/id_xben"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=15 -i $XBEN_KEY"
TIMEOUT=4200  # 70 minutes per challenge
MAX_TURNS=300

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${CYAN}→${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC} $*"; exit 1; }

command -v doctl >/dev/null 2>&1 || die "doctl not found"

# ─── Helpers ────────────────────────────────────────────────────────────────

list_fleet_droplets() {
    doctl compute droplet list --format ID,Name,PublicIPv4,Status --no-header 2>/dev/null \
        | awk -v p="$FLEET_PREFIX" '$2 ~ "^"p { print }'
}

get_snapshot_id() {
    doctl compute snapshot list --format ID,Name --no-header 2>/dev/null \
        | grep "$SNAPSHOT_NAME" | awk '{print $1}' | head -1
}

get_ssh_key_id() {
    local fp
    fp=$(ssh-keygen -l -E md5 -f "${XBEN_KEY}.pub" 2>/dev/null | awk '{print $2}' | sed 's/^MD5://')
    doctl compute ssh-key list --format ID,FingerPrint --no-header 2>/dev/null \
        | grep "$fp" | awk '{print $1}' | head -1
}

# List of already-solved benchmarks on the main droplet (if any)
get_existing_solved() {
    local primary_ip
    primary_ip=$(doctl compute droplet list --format Name,PublicIPv4 --no-header 2>/dev/null \
        | grep '^xben-agent-smith ' | awk '{print $2}' | head -1)
    if [[ -n "$primary_ip" ]]; then
        ssh $SSH_OPTS "root@$primary_ip" "ls /root/runs/ 2>/dev/null | grep '^run_' | sed 's/^run_//'" 2>/dev/null || true
    fi
}

all_benchmarks() {
    python3 -c "
import urllib.request, json
r = urllib.request.urlopen('https://api.github.com/repos/schniggie/validation-benchmarks/contents/benchmarks', timeout=30)
data = json.loads(r.read().decode())
for item in sorted(data, key=lambda x: x['name']):
    if item['type'] == 'dir' and item['name'].startswith('XBEN-'):
        print(item['name'])
"
}

# Split a list into N roughly-equal chunks (stdout: one line per chunk)
split_list() {
    local n=$1
    shift
    python3 -c "
import sys
items = sys.argv[2:]
n = int(sys.argv[1])
# Round-robin: chunk i gets items[i], items[i+n], items[i+2n], ...
chunks = [[] for _ in range(n)]
for i, item in enumerate(items):
    chunks[i % n].append(item)
for chunk in chunks:
    print(' '.join(chunk))
" "$n" "$@"
}

# ─── Command: launch ────────────────────────────────────────────────────────

cmd_launch() {
    local n="$1"; shift
    local explicit_ids=("$@")

    [[ "$n" =~ ^[0-9]+$ ]] || die "First arg must be number of droplets"
    (( n > 0 && n <= 50 )) || die "N must be between 1 and 50"

    # Resolve what benchmarks to run
    if [[ ${#explicit_ids[@]} -gt 0 ]]; then
        local ids=("${explicit_ids[@]}")
    else
        info "Fetching full benchmark list from GitHub..."
        local all_ids=()
        while IFS= read -r line; do all_ids+=("$line"); done < <(all_benchmarks)
        info "  ${#all_ids[@]} benchmarks total"

        info "Checking for existing solved benchmarks on primary droplet..."
        local solved=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && solved+=("$line")
        done < <(get_existing_solved)
        info "  ${#solved[@]} already solved — will skip"

        # Subtract solved from all
        local ids=()
        for id in "${all_ids[@]}"; do
            local found=false
            for s in "${solved[@]}"; do
                if [[ "$id" == "$s" ]]; then found=true; break; fi
            done
            $found || ids+=("$id")
        done
    fi

    local total=${#ids[@]}
    (( total > 0 )) || die "Nothing to run"
    info "  $total benchmark(s) to queue"

    # Clamp n to at most total
    if (( n > total )); then
        warn "Reducing droplet count from $n to $total (1 per challenge)"
        n=$total
    fi

    # Check snapshot + SSH key
    local snap_id ssh_key_id
    snap_id=$(get_snapshot_id)
    [[ -n "$snap_id" ]] || die "No snapshot found. Run ./deploy-do.sh --setup first."
    ssh_key_id=$(get_ssh_key_id)
    [[ -n "$ssh_key_id" ]] || die "SSH key not registered. Run ./deploy-do.sh first."

    # Check API key
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY not set"

    # Split benchmarks into N chunks
    local chunks=()
    while IFS= read -r line; do chunks+=("$line"); done < <(split_list "$n" "${ids[@]}")

    info "Splitting $total challenges across $n droplets:"
    for i in "${!chunks[@]}"; do
        local chunk="${chunks[$i]}"
        local count=$(echo "$chunk" | wc -w | tr -d ' ')
        echo "  Droplet $((i+1)): $count challenge(s) — ${chunk:0:70}$([ ${#chunk} -gt 70 ] && echo '...')"
    done
    echo ""

    printf "  Create $n droplets and start benchmarks? [y/N]: "
    read -r answer
    [[ "${answer:-n}" =~ ^[Yy]$ ]] || die "Aborted"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Create droplets in parallel
    info "Creating $n droplets..."
    local pids=()
    local tmpdir=$(mktemp -d)
    for i in "${!chunks[@]}"; do
        local name="${FLEET_PREFIX}-$(printf '%02d' $((i+1)))"
        local chunk="${chunks[$i]}"
        (
            doctl compute droplet create "$name" \
                --size "$SIZE" --image "$snap_id" --region "$REGION" \
                --ssh-keys "$ssh_key_id" --wait \
                --format ID --no-header > "$tmpdir/$name.id" 2>&1
            echo "$chunk" > "$tmpdir/$name.chunk"
        ) &
        pids+=($!)
    done

    info "Waiting for all $n droplets to provision (~90s)..."
    for pid in "${pids[@]}"; do wait "$pid"; done
    ok "All droplets created"

    # Launch benchmarks on each in parallel
    info "Launching benchmarks on all droplets..."
    local launch_pids=()
    for i in "${!chunks[@]}"; do
        local name="${FLEET_PREFIX}-$(printf '%02d' $((i+1)))"
        local droplet_id
        droplet_id=$(cat "$tmpdir/$name.id")
        local chunk
        chunk=$(cat "$tmpdir/$name.chunk")
        (
            sleep 5
            local ip
            ip=$(doctl compute droplet get "$droplet_id" --format PublicIPv4 --no-header)
            # Wait for SSH
            for j in $(seq 1 30); do
                ssh -n $SSH_OPTS "root@$ip" "echo ok" >/dev/null 2>&1 && break
                sleep 10
            done

            # Prep droplet in one batched ssh (ufw allow is instant — NO reload,
            # which used to race with the immediately-following scp and drop it).
            ssh -n $SSH_OPTS "root@$ip" "set -e
                ufw allow 22/tcp >/dev/null 2>&1 || true
                mkdir -p /root/agent-smith/benchmarks
            " || { echo "  ✗ $name ($ip) prep failed"; exit 1; }

            # Sync runner.py + CTF patch script — fail loudly (no 2>/dev/null).
            scp $SSH_OPTS "$SCRIPT_DIR/runner.py" "root@$ip:/root/agent-smith/benchmarks/runner.py" \
                || { echo "  ✗ $name ($ip) scp runner.py failed"; exit 1; }
            scp $SSH_OPTS "$SCRIPT_DIR/_ctf_patch.sh" "root@$ip:/tmp/_ctf_patch.sh" \
                || { echo "  ✗ $name ($ip) scp _ctf_patch.sh failed"; exit 1; }

            # Re-register MCP, apply CTF patch, install pyyaml — one batched ssh.
            ssh -n $SSH_OPTS "root@$ip" "set -e
                /usr/bin/claude mcp remove pentest-agent 2>/dev/null || true
                /usr/bin/claude mcp add --scope user pentest-agent -- /root/.local/bin/poetry -C /root/agent-smith run python -m mcp_server >/dev/null
                bash /tmp/_ctf_patch.sh
                pip3 install pyyaml >/dev/null 2>&1 || true
            " || { echo "  ✗ $name ($ip) setup failed"; exit 1; }

            # Start benchmark
            local run_cmd="export ANTHROPIC_API_KEY=\"$ANTHROPIC_API_KEY\" && export PATH=/root/.local/bin:\$PATH && cd /root/agent-smith && python3 -u benchmarks/runner.py --agent claude --timeout $TIMEOUT --max-turns $MAX_TURNS --benchmarks $chunk --output /root/runs 2>&1 | tee -a /root/benchmark.log"
            ssh -n $SSH_OPTS "root@$ip" "nohup bash -c '$run_cmd' > /root/benchmark-nohup.log 2>&1 &" \
                || { echo "  ✗ $name ($ip) nohup launch failed"; exit 1; }
            echo "  ✓ $name ($ip) launched"
        ) &
        launch_pids+=($!)
    done

    for pid in "${launch_pids[@]}"; do wait "$pid"; done
    rm -rf "$tmpdir"

    ok "Fleet launched"
    echo ""
    echo "  Monitor:   ./fleet.sh status"
    echo "  Progress:  ./fleet.sh progress"
    echo "  Pull:      ./fleet.sh pull ./runs"
    echo "  Destroy:   ./fleet.sh destroy"
    echo ""
}

# ─── Command: status ────────────────────────────────────────────────────────

cmd_status() {
    local rows
    rows=$(list_fleet_droplets)
    if [[ -z "$rows" ]]; then
        warn "No fleet droplets found"
        return
    fi

    echo ""
    echo "  Fleet status"
    echo "  ============"
    echo ""
    printf "  %-20s %-16s %-10s %-12s %s\n" "NAME" "IP" "STATUS" "BENCHMARK" "RUNNING"
    echo "  $(printf '%.0s─' {1..80})"

    while read -r line; do
        local id name ip status
        id=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        ip=$(echo "$line" | awk '{print $3}')
        status=$(echo "$line" | awk '{print $4}')

        local bench="-" running="-"
        if [[ "$status" == "active" && -n "$ip" ]]; then
            bench=$(ssh -n $SSH_OPTS "root@$ip" "docker ps --format '{{.Names}}' 2>/dev/null | grep xben | head -1 | cut -d- -f1-3" 2>/dev/null || echo "-")
            [[ -z "$bench" ]] && bench="idle"
            running=$(ssh -n $SSH_OPTS "root@$ip" "pgrep -f runner.py >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo "?")
        fi
        printf "  %-20s %-16s %-10s %-12s %s\n" "$name" "$ip" "$status" "$bench" "$running"
    done <<< "$rows"
    echo ""
}

# ─── Command: progress ─────────────────────────────────────────────────────

cmd_progress() {
    local rows
    rows=$(list_fleet_droplets)
    if [[ -z "$rows" ]]; then
        warn "No fleet droplets"
        return
    fi

    echo ""
    echo "  Fleet progress"
    echo "  =============="
    echo ""

    local total_solved=0 total_done=0 total_cost=0

    while read -r line; do
        local name ip
        name=$(echo "$line" | awk '{print $2}')
        ip=$(echo "$line" | awk '{print $3}')
        [[ -z "$ip" ]] && continue

        local stats
        stats=$(ssh -n $SSH_OPTS "root@$ip" "python3 -c '
import json, os
runs = \"/root/runs\"
if not os.path.isdir(runs):
    print(\"0|0|0.0|-\"); exit(0)
dirs = [d for d in os.listdir(runs) if d.startswith(\"run_\")]
solved = 0
unsolved = 0
cost = 0.0
latest = \"\"
for d in dirs:
    p = os.path.join(runs, d, \"result.json\")
    if os.path.exists(p):
        try:
            r = json.load(open(p))
            if r[\"evaluation\"][\"flag_extracted\"]:
                solved += 1
            else:
                unsolved += 1
            cost += r.get(\"agent_execution\", {}).get(\"resource_usage\", {}).get(\"total_cost\", 0) or 0
            latest = r[\"benchmark_id\"]
        except: pass
print(f\"{solved}|{unsolved}|{cost:.2f}|{latest}\")
' 2>/dev/null" 2>/dev/null || echo "0|0|0.0|-")

        IFS='|' read -r solved unsolved cost latest <<< "$stats"
        local done=$((solved + unsolved))
        printf "  %-20s %-16s %2d solved · %2d failed · \$%6s · last: %s\n" \
            "$name" "$ip" "$solved" "$unsolved" "$cost" "${latest:-waiting}"

        total_solved=$((total_solved + solved))
        total_done=$((total_done + done))
        total_cost=$(python3 -c "print($total_cost + $cost)")
    done <<< "$rows"

    echo ""
    echo "  ────────────────────────────────────────────────────────"
    printf "  TOTAL: %d solved / %d attempted · \$%.2f\n" "$total_solved" "$total_done" "$total_cost"
    echo ""
}

# ─── Command: pull ──────────────────────────────────────────────────────────

cmd_pull() {
    local dest="${1:-./runs}"
    mkdir -p "$dest"

    local rows
    rows=$(list_fleet_droplets)
    [[ -n "$rows" ]] || die "No fleet droplets"

    info "Pulling results into $dest..."
    while read -r line; do
        local name ip
        name=$(echo "$line" | awk '{print $2}')
        ip=$(echo "$line" | awk '{print $3}')
        [[ -z "$ip" ]] && continue

        info "  $name ($ip)..."
        scp $SSH_OPTS -r "root@$ip:/root/runs/run_*" "$dest/" 2>/dev/null || warn "  no results on $name"
    done <<< "$rows"

    # Also pull from primary if exists
    local primary_ip
    primary_ip=$(doctl compute droplet list --format Name,PublicIPv4 --no-header 2>/dev/null \
        | grep '^xben-agent-smith ' | awk '{print $2}')
    if [[ -n "$primary_ip" ]]; then
        info "  xben-agent-smith ($primary_ip)..."
        scp $SSH_OPTS -r "root@$primary_ip:/root/runs/run_*" "$dest/" 2>/dev/null || true
    fi

    ok "Pulled $(ls "$dest" | grep -c '^run_' 2>/dev/null || echo 0) result folder(s)"
}

# ─── Command: fix ──────────────────────────────────────────────────────────
# Re-runs setup + start on existing fleet droplets. Use when an earlier
# launch failed silently (e.g. broken snapshot) and droplets are running
# but no benchmarks are going.

cmd_fix() {
    local rows
    rows=$(list_fleet_droplets)
    [[ -n "$rows" ]] || die "No fleet droplets to fix"

    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY not set"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Need to re-derive which chunks go to which droplet.
    # Fetch benchmark list, exclude primary's solved, split across N droplets
    # in the same deterministic order fleet-01..fleet-N.
    info "Recomputing chunk assignments..."
    local all_ids=()
    while IFS= read -r line; do all_ids+=("$line"); done < <(all_benchmarks)

    local solved=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && solved+=("$line")
    done < <(get_existing_solved)

    local ids=()
    for id in "${all_ids[@]}"; do
        local found=false
        for s in "${solved[@]}"; do
            if [[ "$id" == "$s" ]]; then found=true; break; fi
        done
        $found || ids+=("$id")
    done

    local n
    n=$(echo "$rows" | wc -l | tr -d ' ')
    info "  $n droplet(s), ${#ids[@]} benchmark(s)"

    local chunks=()
    while IFS= read -r line; do chunks+=("$line"); done < <(split_list "$n" "${ids[@]}")

    # Order droplets by name so chunk assignment is deterministic
    local sorted_rows
    sorted_rows=$(echo "$rows" | sort -k2)

    local i=0
    local pids=()
    while IFS= read -r line; do
        local name ip
        name=$(echo "$line" | awk '{print $2}')
        ip=$(echo "$line" | awk '{print $3}')
        local chunk="${chunks[$i]}"
        i=$((i + 1))
        [[ -z "$ip" ]] && continue

        (
            # Prep in one batched ssh — no ufw reload (races with scp).
            ssh -n $SSH_OPTS "root@$ip" "set -e
                ufw allow 22/tcp >/dev/null 2>&1 || true
                mkdir -p /root/agent-smith/benchmarks
                pkill -f runner.py 2>/dev/null || true
            " || { echo "  ✗ $name ($ip) prep failed"; exit 1; }

            # Sync runner + patch — fail loudly.
            scp $SSH_OPTS "$SCRIPT_DIR/runner.py" "root@$ip:/root/agent-smith/benchmarks/runner.py" \
                || { echo "  ✗ $name ($ip) scp runner.py failed"; exit 1; }
            scp $SSH_OPTS "$SCRIPT_DIR/_ctf_patch.sh" "root@$ip:/tmp/_ctf_patch.sh" \
                || { echo "  ✗ $name ($ip) scp _ctf_patch.sh failed"; exit 1; }

            # Re-register MCP, apply CTF patch, install pyyaml — one batched ssh.
            ssh -n $SSH_OPTS "root@$ip" "set -e
                /usr/bin/claude mcp remove pentest-agent 2>/dev/null || true
                /usr/bin/claude mcp add --scope user pentest-agent -- /root/.local/bin/poetry -C /root/agent-smith run python -m mcp_server >/dev/null
                bash /tmp/_ctf_patch.sh
                pip3 install pyyaml >/dev/null 2>&1 || true
            " || { echo "  ✗ $name ($ip) setup failed"; exit 1; }

            # Start benchmark
            local run_cmd="export ANTHROPIC_API_KEY=\"$ANTHROPIC_API_KEY\" && export PATH=/root/.local/bin:\$PATH && cd /root/agent-smith && python3 -u benchmarks/runner.py --agent claude --timeout $TIMEOUT --max-turns $MAX_TURNS --benchmarks $chunk --output /root/runs 2>&1 | tee -a /root/benchmark.log"
            ssh -n $SSH_OPTS "root@$ip" "nohup bash -c '$run_cmd' > /root/benchmark-nohup.log 2>&1 &" \
                || { echo "  ✗ $name ($ip) nohup launch failed"; exit 1; }
            echo "  ✓ $name ($ip) — ${chunk}"
        ) &
        pids+=($!)
    done <<< "$sorted_rows"

    info "Fixing $n droplet(s) in parallel..."
    for pid in "${pids[@]}"; do wait "$pid"; done
    ok "All droplets fixed and benchmarks started"
}

# ─── Command: destroy ──────────────────────────────────────────────────────

cmd_destroy() {
    local rows
    rows=$(list_fleet_droplets)
    [[ -n "$rows" ]] || { warn "No fleet droplets to destroy"; return; }

    echo ""
    echo "  These droplets will be destroyed:"
    echo "$rows" | awk '{printf "    %s (%s)\n", $2, $3}'
    echo ""
    printf "  Confirm destroy? [y/N]: "
    read -r answer
    [[ "${answer:-n}" =~ ^[Yy]$ ]] || { info "Aborted"; return; }

    while read -r line; do
        local id name
        id=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        doctl compute droplet delete "$id" --force && ok "Destroyed $name"
    done <<< "$rows"
}

# ─── Dispatch ──────────────────────────────────────────────────────────────

case "${1:-}" in
    launch)   shift; cmd_launch "$@" ;;
    fix)      cmd_fix ;;
    status)   cmd_status ;;
    progress) cmd_progress ;;
    pull)     shift; cmd_pull "$@" ;;
    destroy)  cmd_destroy ;;
    *)
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  launch N [BENCHMARKS...]  Create N droplets and split benchmarks"
        echo "  status                     Show all fleet droplets"
        echo "  progress                   Per-droplet solved/failed counts"
        echo "  pull [DEST]                Scp all results to DEST (default: ./runs)"
        echo "  destroy                    Destroy all fleet droplets"
        echo ""
        echo "Example:"
        echo "  ./fleet.sh launch 15"
        echo "  ./fleet.sh progress"
        echo "  ./fleet.sh pull ./runs"
        echo "  ./fleet.sh destroy"
        exit 1
        ;;
esac
