#!/bin/bash
# PACE BD Weekly Batch — auto-push script
# Picks up the finished index.html that Cowork saves locally and pushes it to
# GitHub if it contains a batch number newer than what's already live.
# Runs via launchd (see ~/Library/LaunchAgents/com.pace.bd-autopush.plist).
#
# DESIGN (rewritten 2026-08-24 after a real regression — see below):
# This script never trusts Cowork's saved file as a whole. Cowork's file is
# used ONLY as a source to extract four well-defined, always-present pieces:
#   1. the new batchN array(s)
#   2. the batchScanCounts + seedBatches lines
#   3. the Executive Summary paragraph
#   4. the entire Swiss Events view block
# Those four pieces are spliced into a fresh copy of the CURRENT LIVE file.
# Everything else on the page (favicon, CSS, the reached-out tick feature,
# the PACE Commercial Fit methodology section, anything else added to the
# dashboard over time) is taken ONLY from the live file and can never be
# touched by a batch push, no matter what template Cowork used to generate
# its file. If extraction of any of the four pieces fails, or the merged
# result is missing a protected feature, the run is refused and flagged for
# review rather than silently degrading the live site.
#
# Why this exists: on 2026-08-19 (batch 8), Cowork saved a file built from a
# stale template that predated the favicon, the reached-out tick feature (and
# the reachedOutIds array holding 19 already-ticked leads), and the PACE
# Commercial Fit UI. The previous version of this script only tried to merge
# the reachedOutIds array specifically, had a logic bug that let even that
# fail silently, and blindly pushed Cowork's stale file on any merge failure.
# The whole live site regressed for several hours before being caught and
# manually reconstructed from git history. This rewrite makes that class of
# failure structurally impossible, not just less likely.
#
# Failure handling:
#   - Cowork's source fails syntax validation, or any of the four pieces
#     can't be cleanly extracted, or the merged result is missing a protected
#     feature -> NOT pushed, NOT offered for manual upload. Saved to
#     REVIEW_NEEDED file + notification.
#   - Extraction succeeds but git/push fails (auth, network, etc.) -> NOT
#     pushed, but a ready-to-upload copy + step-by-step instructions are left
#     in the Business Development folder, plus a desktop notification.

set -u

SOURCE="$HOME/pace-bd/inbox/index.html"
REPO="$HOME/pace-bd/Business-Development"
LOG="$REPO/autopush.log"
MANUAL_FILE="$HOME/pace-bd/inbox/NEEDS_MANUAL_UPLOAD.html"
MANUAL_INSTR="$HOME/pace-bd/inbox/NEEDS_MANUAL_UPLOAD_INSTRUCTIONS.txt"
REVIEW_FILE="$HOME/pace-bd/inbox/REVIEW_NEEDED_invalid.html"
MERGED_FILE="/tmp/pace_autopush_merged.html"

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

if [ -n "$repo_batch" ] && [ "$src_batch" -lt "$repo_batch" ]; then
  log "Source batch (${src_batch}) is older than live (${repo_batch}) — skipping, not touching live."
  rm -f "$MANUAL_FILE" "$MANUAL_INSTR" "$REVIEW_FILE" "$MERGED_FILE" 2>/dev/null
  exit 0
fi

# Same batch number as live: don't just assume there is nothing to do. The
# Content dashboard's sibling script hit a real case of this: batch 1's
# first save only had 4 of 7 leads, Cowork finished writing the rest a few
# minutes later, but every 15-min poll after that saw "still batch1" and
# silently never re-checked the content, so the missing leads went
# unpublished for hours. Compare the actual content of that batch's array
# between source and live, and still push if it genuinely differs.
same_batch_content_changed=false
if [ -n "$repo_batch" ] && [ "$src_batch" -eq "$repo_batch" ]; then
  src_hash=$(python3 - "$SOURCE" "$src_batch" <<'PY'
import re, sys, hashlib
content = open(sys.argv[1], encoding='utf-8').read()
n = sys.argv[2]
m = re.search(r'const batch%s = \[.*\n\];\n(?=const |\Z)' % n, content, re.S)
print(hashlib.sha256(m.group(0).encode('utf-8')).hexdigest() if m else 'NONE')
PY
)
  live_hash=$(python3 - "index.html" "$repo_batch" <<'PY'
import re, sys, hashlib
content = open(sys.argv[1], encoding='utf-8').read()
n = sys.argv[2]
m = re.search(r'const batch%s = \[.*\n\];\n(?=const |\Z)' % n, content, re.S)
print(hashlib.sha256(m.group(0).encode('utf-8')).hexdigest() if m else 'NONE')
PY
)
  if [ "$src_hash" = "$live_hash" ]; then
    log "No new batch (source=batch${src_batch}, live=batch${repo_batch}), and batch ${src_batch}'s content is unchanged. Nothing to push."
    rm -f "$MANUAL_FILE" "$MANUAL_INSTR" "$REVIEW_FILE" "$MERGED_FILE" 2>/dev/null
    exit 0
  fi
  log "Batch ${src_batch} content differs from what is live even though the batch number is the same — treating as an update to push, not a duplicate."
  same_batch_content_changed=true
fi

# --- source syntax validation: brace/bracket balance inside <script> blocks ---
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
  log "Source validation failed ($check) on batch ${src_batch} — NOT pushed. Copy saved for review at '$REVIEW_FILE'."
  notify "PACE BD batch ${src_batch}: content problem" "Source validation failed ($check) — not pushed. See REVIEW_NEEDED_invalid.html."
  exit 1
fi

# --- extract the four well-defined pieces from source and splice onto live ---
extract_status="SKIPPED_FETCH_FAILED"
if $fetch_ok; then
  extract_status=$(python3 - "$SOURCE" "$REPO/index.html" "$MERGED_FILE" <<'PY'
import re, sys

src_path, live_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path, encoding='utf-8').read()
live = open(live_path, encoding='utf-8').read()

errors = []

# Match a batch array to its true end: the next `const ` declaration or end
# of file, never just the first "\n];\n" the regex happens to hit. A plain
# non-greedy `.*?\n\];\n` can stop early at an internal array field inside
# one of the lead objects (e.g. a `secondaryPaceServices:[...]` line that
# happens to end with "];"), silently truncating the batch and losing leads
# with no syntax error to catch it. This is exactly what happened on the
# Content dashboard's batch 1 (3 of 7 leads, including Victorinox, went
# missing this way) before this fix was ported over here.
def batch_pattern(n):
    return re.compile(r'const batch%d = \[.*\n\];\n(?=const |\Z)' % n, re.S)

live_batches = set(int(n) for n in re.findall(r'const batch(\d+) = \[', live))
src_batches = set(int(n) for n in re.findall(r'const batch(\d+) = \[', src))

new_batches = sorted(src_batches - live_batches)
existing_batches = sorted(src_batches & live_batches)

new_batch_blocks = ''
for n in new_batches:
    m = batch_pattern(n).search(src)
    if not m:
        errors.append(f'COULD_NOT_EXTRACT_BATCH_{n}')
    else:
        new_batch_blocks += m.group(0)

# Batches that already exist live: only resync ones whose content actually
# changed, e.g. Cowork finished writing more leads into the same batch
# number after the first save was already pushed.
changed_batches = []
for n in existing_batches:
    m_src = batch_pattern(n).search(src)
    m_live = batch_pattern(n).search(live)
    if not m_src:
        errors.append(f'COULD_NOT_EXTRACT_BATCH_{n}')
        continue
    if not m_live:
        errors.append(f'COULD_NOT_FIND_LIVE_BATCH_{n}')
        continue
    if m_src.group(0) != m_live.group(0):
        changed_batches.append((n, m_src.group(0)))

if not new_batches and not changed_batches:
    errors.append('NO_NEW_OR_CHANGED_BATCH_ARRAY_IN_SOURCE')

m_counts = re.search(r'const batchScanCounts = \{.*?\};[^\n]*\nconst seedBatches = \[.*?\];', src, re.S)
if not m_counts:
    errors.append('COULD_NOT_EXTRACT_COUNTS_LINES')

m_exec = re.search(r'<h2>Executive Summary</h2>\s*<p[^>]*>.*?</p>', src, re.S)
if not m_exec:
    errors.append('COULD_NOT_EXTRACT_EXEC_SUMMARY')

m_swiss = re.search(r'<div class="view" id="view-swiss-events">.*?\n    </div>\n', src, re.S)
if not m_swiss:
    errors.append('COULD_NOT_EXTRACT_SWISS_EVENTS')

if errors:
    print('EXTRACT_FAIL:' + ','.join(errors))
    sys.exit(0)

def fix_dashes(text):
    # Never block a push over dashes — clean them instead, using the same
    # rules applied by hand for batches 8 and 9. Order matters: ranges and
    # structured fields are fixed first (narrow, safe patterns), then
    # whatever em/en dashes remain (genuine prose asides) become commas,
    # then any leftover of either character (belt and suspenders) also
    # becomes a comma so nothing can slip through un-fixed.
    text = re.sub(r'(?<=\S)[—–](?=\S)', '-', text)  # e.g. "20,000—100,000" -> hyphen
    def colon_fix(m):
        return m.group(0).replace('—', ':').replace('–', ':').replace(' :', ':')
    text = re.sub(r"industry:'[^']*[—–][^']*'", colon_fix, text)
    text = re.sub(r"source:'[^']*[—–][^']*'", colon_fix, text)
    text = re.sub(r'\s[—–]\s', ', ', text)  # " — " / " – " (prose aside) -> ", "
    text = text.replace('—', ',').replace('–', ',')  # any straggler
    return text

changed_blocks_text = ''.join(b for _, b in changed_batches)
dash_count_before = (new_batch_blocks + changed_blocks_text + m_exec.group(0) + m_swiss.group(0)).count('—') + \
                     (new_batch_blocks + changed_blocks_text + m_exec.group(0) + m_swiss.group(0)).count('–')
new_batch_blocks = fix_dashes(new_batch_blocks)
exec_block = fix_dashes(m_exec.group(0))
swiss_block = fix_dashes(m_swiss.group(0))

merged = live

# Resync any already-live batch whose content changed, in place, before
# touching anything else.
for n, block in changed_batches:
    old = batch_pattern(n).search(merged)
    if not old:
        print(f'EXTRACT_FAIL:COULD_NOT_FIND_LIVE_BATCH_{n}_AT_MERGE_TIME')
        sys.exit(0)
    merged = merged[:old.start()] + fix_dashes(block) + merged[old.end():]

old_counts = re.search(r'const batchScanCounts = \{.*?\};[^\n]*\nconst seedBatches = \[.*?\];', merged, re.S)
if not old_counts:
    print('EXTRACT_FAIL:LIVE_COUNTS_LINE_NOT_FOUND')
    sys.exit(0)
merged = merged[:old_counts.start()] + new_batch_blocks + m_counts.group(0) + merged[old_counts.end():]

old_exec = re.search(r'<h2>Executive Summary</h2>\s*<p[^>]*>.*?</p>', merged, re.S)
if not old_exec:
    print('EXTRACT_FAIL:LIVE_EXEC_SUMMARY_NOT_FOUND')
    sys.exit(0)
merged = merged[:old_exec.start()] + exec_block + merged[old_exec.end():]

old_swiss = re.search(r'<div class="view" id="view-swiss-events">.*?\n    </div>\n', merged, re.S)
if not old_swiss:
    print('EXTRACT_FAIL:LIVE_SWISS_EVENTS_NOT_FOUND')
    sys.exit(0)
merged = merged[:old_swiss.start()] + swiss_block + merged[old_swiss.end():]

blocks = re.findall(r'<script>(.*?)</script>', merged, re.S)
js = ''.join(blocks)
if js.count('{') != js.count('}') or js.count('[') != js.count(']'):
    print('EXTRACT_FAIL:UNBALANCED_AFTER_MERGE')
    sys.exit(0)

if '—' in merged or '–' in merged:
    print('EXTRACT_FAIL:DASHES_SURVIVED_AUTO_FIX')
    sys.exit(0)

protected = [('rel="icon"', 'FAVICON'), ('reach-tick', 'REACH_TICK'),
             ('reachedOutIds', 'REACHED_OUT_IDS'), ('pace-service', 'PACE_SERVICE_CSS'),
             ('PACE Commercial Fit', 'COMMERCIAL_FIT_SECTION')]
missing = [label for marker, label in protected if merged.count(marker) == 0]
if missing:
    print('EXTRACT_FAIL:MISSING_AFTER_MERGE:' + ','.join(missing))
    sys.exit(0)

with open(out_path, 'w', encoding='utf-8') as f:
    f.write(merged)
print(f'OK:{dash_count_before}')
PY
)
fi

if [[ "$extract_status" != OK:* ]]; then
  cp "$SOURCE" "$REVIEW_FILE"
  log "Extraction/merge failed for batch ${src_batch}: $extract_status — NOT pushed. Live site untouched. Source copy saved for review at '$REVIEW_FILE'."
  notify "PACE BD batch ${src_batch}: could not safely merge" "$extract_status — nothing pushed, live site untouched. See REVIEW_NEEDED_invalid.html and autopush.log."
  exit 1
fi
dash_note=""
dashes_cleaned="${extract_status#OK:}"
if [ -n "$dashes_cleaned" ] && [ "$dashes_cleaned" != "0" ]; then
  dash_note=" ($dashes_cleaned dash character(s) auto-cleaned from the new content before pushing)"
fi

# --- attempt the push using the merged (feature-preserving) file ---
cp "$MERGED_FILE" "$REPO/index.html"
git add index.html
if git diff --cached --quiet; then
  log "Merged file but git sees no changes — nothing to commit."
  rm -f "$MERGED_FILE" 2>/dev/null
  exit 0
fi

if $same_batch_content_changed; then
  commit_msg="Update batch ${src_batch} content (corrected/completed after initial save)"
else
  commit_msg="Weekly BD scan, batch ${src_batch}"
fi

if git commit -m "$commit_msg" -q && git push -q; then
  sha=$(git rev-parse --short HEAD)
  log "Pushed batch ${src_batch} successfully (commit ${sha}), merged onto the current live file — all existing features preserved.${dash_note}"
  rm -f "$MANUAL_FILE" "$MANUAL_INSTR" "$REVIEW_FILE" "$MERGED_FILE" 2>/dev/null
  log "=== run end ==="
  exit 0
fi

cp "$MERGED_FILE" "$MANUAL_FILE"
cat > "$MANUAL_INSTR" <<EOF
Automatic push FAILED for batch ${src_batch} — likely a git auth or network issue.
Check autopush.log for the exact error. Common fix: re-run in Terminal:
  gh auth login --hostname github.com --git-protocol https --web

The file at $MANUAL_FILE already has batch ${src_batch}'s new content merged
onto the current live site (all existing features preserved) and is ready to
upload manually:

1. Go to https://github.com/noemie-PACE/Business-Development-Sport
2. Open index.html, click the pencil (edit) icon
3. Select all, delete, paste in the full contents of the file above
4. Commit directly to main with message: Weekly BD scan, batch ${src_batch}

Once git access is working again, this will resolve itself automatically on
the next 15-minute check — no need to do anything else after a manual upload.
EOF
log "git push failed for batch ${src_batch} — left ready-to-upload (already merged) copy at '$MANUAL_FILE' and instructions at '$MANUAL_INSTR'."
notify "PACE BD batch ${src_batch}: auto-push failed" "Manual upload needed — ready file is in the Business Development folder (NEEDS_MANUAL_UPLOAD.html)."
exit 1
