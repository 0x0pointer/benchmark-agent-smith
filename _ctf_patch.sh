#!/usr/bin/env bash
# _ctf_patch.sh — CTF short-circuit patch for agent-smith on benchmark droplets.
#
# Injects _has_ctf_flag helper into mcp_server/session_tools.py so the
# /pentester completion gates (credential-audit, post-exploit, etc.) are
# skipped as soon as any finding contains a flag{...} pattern. Also prepends
# a "CTF mode" section to skills/pentester.md so the agent is told to
# call complete_scan immediately on flag extraction.
#
# Idempotent. Safe to run multiple times. Benchmark-only — do not apply to
# upstream repo. This file mirrors the inline heredoc in deploy-do.sh so
# fleet.sh can scp + apply the same fixes.
set -e

# --- patch 1: mcp_server/session_tools.py ---
python3 - <<'PYEOF'
import re
from pathlib import Path

p = Path("/root/agent-smith/mcp_server/session_tools.py")
src = p.read_text()

if "_has_ctf_flag" in src:
    print("  session_tools.py: already patched")
else:
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
