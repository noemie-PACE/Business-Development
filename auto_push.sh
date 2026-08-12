#!/bin/bash
# PACE BD Weekly Batch — auto-push script
# Picks up the finished index.html that Cowork saves locally and pushes it to
# GitHub if it contains a batch number newer than what's already live.
# Runs via launchd (see ~/Library/LaunchAgents/com.pace.bd-autopush.plist).
#
# Failure handling:
#   - Content fails validation (broken/truncated JS)  -> NOT pushed, NOT offered
#     for manual upload (it's broken). Saved to REVIEW_NEEDED file + notification.
#   - Content is valid but git/push fails (auth, network, etc.) -> NOT pushed,
#     but a ready-to-upload copy + step-by-step instructions are left in the
#     Business Development folder, plus a desktop notification.

set -u

SOURCE="$HOME/Desktop/PACE SNA/Business Development/index.html"
REPO="$HOME/Desktop/Business-Development"
LOG="$REPO/autopush.log"
MANUAL_FILE="$HOME/Desktop/PACE SNA/Business Development/NEEDS_MANUAL_UPLOAD.html"
MANUAL_INSTR="$HOME/Desktop/PACE SNA/Business Development/NEEDS_MANUAL_UPLOAD_INSTRUCTIONS.txt"
REVIEW_FILE="$HOME/Desktop/PACE SNA/Business Development/REVIEW_NEEDED_invalid.html"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

notify() {
  # title, message
  osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" >/dev/null 2>&1
}

log "=== run start ==="

if [ ! -f "$SOURCE" ]; then
  log "No source file found at '$SOURCE' — nothing to do."
  exit 0
fi

cd "$REPO" || { log "ERROR: repo dir '$REPO' not found."; exit 1; }

# Safety check: never blow away in-progress manual edits. This script used to
# `git reset --hard origin/main` unconditionally, which silently destroyed
# uncommitted edits (happened twice during development — once from a manual
# test run, once from this job's own normal 15-min poll catching an edit
# mid-flight). If anything is uncommitted, skip this run entirely rather than
# guess whether it's safe to discard.
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "SKIPPED: uncommitted local changes present in '$REPO' — not touching them. Commit or stash before the next 15-min poll, or this run is simply skipped harmlessly."
  exit 0
fi

fetch_ok=true
if ! git fetch origin main -q; then
  fetch_ok=false
  log "WARNING: git fetch failed — will use last known local state to compare batch numbers."
else
  git checkout main -q
  git reset --hard origin/main -q
fi

repo_batch=$(grep -oE 'const batch[0-9]+ = \[' index.html | grep -oE '[0-9]+' | sort -n | tail -1)
src_batch=$(grep -oE 'const batch[0-9]+ = \[' "$SOURCE" | grep -oE '[0-9]+' | sort -n | tail -1)

if [ -z "$src_batch" ]; then
  log "Source file has no recognizable batchN array — skipping, not touching live."
  exit 0
fi

if [ -z "$repo_batch" ] || [ "$src_batch" -le "$repo_batch" ]; then
  log "No new batch (source=batch${src_batch:-none}, live=batch${repo_batch:-none}). Nothing to push."
  # Clear any stale failure flags left over from a problem that has since resolved
  rm -f "$MANUAL_FILE" "$MANUAL_INSTR" "$REVIEW_FILE" 2>/dev/null
  exit 0
fi

# --- content validation: brace/bracket balance inside <script> blocks ---
check=$(python3 - "$SOURCE" <<'PY'
import re, sys
content = open(sys.argv[1], encoding='utf-8').read()
blocks = re.findall(r'<script>(.*?)</script>', content, re.S)
js = "".join(blocks)
if not js.strip():
    print("NO_SCRIPT")
elif js.count('{') != js.count('}') or js.count('[') != js.count(']'):
    print("UNBALANCED")
else:
    print("OK")
PY
)

if [ "$check" != "OK" ]; then
  cp "$SOURCE" "$REVIEW_FILE"
  log "Validation failed ($check) on batch ${src_batch} — NOT pushed, NOT offered for manual upload (content looks broken). Copy saved for review at '$REVIEW_FILE'."
  notify "PACE BD batch ${src_batch}: content problem" "Validation failed ($check) — not pushed. Needs a look before anything goes live; see REVIEW_NEEDED_invalid.html."
  exit 1
fi

# --- attempt the push ---
push_failed=false
if ! $fetch_ok; then
  push_failed=true
else
  # Merge, don't blind-overwrite: reachedOutIds on origin/main (index.html here,
  # already reset to fresh origin above) may be newer than what Cowork's saved
  # file was based on if a reached-out tick landed via the GitHub Action after
  # Cowork fetched its base copy. Carry origin's reachedOutIds forward into the
  # file we're about to push, rather than trusting Cowork's possibly-stale one.
  merge_check=$(python3 - "$SOURCE" "$REPO/index.html" <<'PY'
import re, sys
src_path, live_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding='utf-8').read()
live = open(live_path, encoding='utf-8').read()

live_m = re.search(r"const reachedOutIds = \[.*?\];", live, re.S)
src_m = re.search(r"const reachedOutIds = \[.*?\];", src, re.S)

if live_m and src_m:
    merged = src[:src_m.start()] + live_m.group(0) + src[src_m.end():]
elif src_m:
    merged = src  # live had none (unexpected/older file) — keep source's as-is
else:
    print("NO_REACHED_OUT_ARRAY")
    sys.exit(0)

blocks = re.findall(r'<script>(.*?)</script>', merged, re.S)
js = "".join(blocks)
if js.count('{') != js.count('}') or js.count('[') != js.count(']'):
    print("UNBALANCED_AFTER_MERGE")
    sys.exit(0)

with open(src_path, 'w', encoding='utf-8') as f:
    f.write(merged)
print("OK")
PY
)
  if [ "$merge_check" != "OK" ]; then
    log "reachedOutIds merge check: $merge_check — falling back to Cowork's file as-is (may not reflect the very latest reached-out ticks, will self-correct next batch)."
  fi
  cp "$SOURCE" "$REPO/index.html"
  git add index.html
  if git diff --cached --quiet; then
    log "Copied file but git sees no changes — nothing to commit."
    exit 0
  fi
  if git commit -m "Weekly BD scan, batch ${src_batch}" -q && git push -q; then
    sha=$(git rev-parse --short HEAD)
    log "Pushed batch ${src_batch} successfully (commit ${sha})."
    rm -f "$MANUAL_FILE" "$MANUAL_INSTR" "$REVIEW_FILE" 2>/dev/null
    log "=== run end ==="
    exit 0
  else
    push_failed=true
  fi
fi

if $push_failed; then
  cp "$SOURCE" "$MANUAL_FILE"
  cat > "$MANUAL_INSTR" <<EOF
Automatic push FAILED for batch ${src_batch} — likely a git auth or network issue.
Check autopush.log for the exact error. Common fix: re-run in Terminal:
  gh auth login --hostname github.com --git-protocol https --web

The finished file already passed validation and is ready to upload manually:
  $MANUAL_FILE

To upload it manually:
1. Go to https://github.com/noemie-PACE/Business-Development
2. Open index.html, click the pencil (edit) icon
3. Select all, delete, paste in the full contents of the file above
4. Commit directly to main with message: Weekly BD scan, batch ${src_batch}

Once git access is working again, this will resolve itself automatically on
the next 15-minute check — no need to do anything else after a manual upload.
EOF
  log "git push failed for batch ${src_batch} — left ready-to-upload copy at '$MANUAL_FILE' and instructions at '$MANUAL_INSTR'."
  notify "PACE BD batch ${src_batch}: auto-push failed" "Manual upload needed — ready file is in the Business Development folder (NEEDS_MANUAL_UPLOAD.html)."
  exit 1
fi

log "=== run end ==="
