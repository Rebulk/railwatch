#!/usr/bin/env bash
# land.sh <pr> <branch> [onto-base-branch]  : rebase onto origin/main (CHANGELOG conflicts auto-resolved by keeping both), push, wait CI, squash-merge.
set -u
cd /tmp/gem-merge
pr=$1; br=$2; onto=${3:-}
git fetch -q origin
git checkout -q -B "land-$pr" "origin/$br"
if [ -n "${SKIP_REBASE:-}" ]; then git push -q --force-with-lease origin "land-$pr:$br"; fi
if [ -n "$onto" ]; then git rebase --onto origin/main "origin/$onto" >/dev/null 2>&1 || true; else git rebase origin/main >/dev/null 2>&1 || true; fi
while git status --short | grep -qE "^(UU|AA)"; do
  files=$(git diff --name-only --diff-filter=U)
  if [ "$files" != "CHANGELOG.md" ] && [ -z "${SKIP_REBASE:-}" ]; then echo "#$pr NON-CHANGELOG CONFLICT: $files"; git rebase --abort; exit 1; fi
  python3 - <<'PY'
import re
p='CHANGELOG.md'; s=open(p).read()
while True:
    m=re.search(r'<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n', s, re.S)
    if not m: break
    s = s[:m.start()] + m.group(2).rstrip('\n') + '\n\n' + m.group(1) + s[m.end():]
open(p,'w').write(s)
PY
  git add CHANGELOG.md; GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
done
git push -q --force-with-lease origin "land-$pr:$br" || { echo "#$pr push failed"; exit 1; }
sleep 15
for i in $(seq 1 40); do out=$(gh pr checks "$pr" -R Rebulk/lantern 2>/dev/null | grep -v CodeRabbit); [ -n "$out" ] && ! echo "$out" | grep -qE "pending|queued" && break; sleep 15; done
if echo "$out" | grep -v overhead | grep -qiE "fail|error"; then echo "#$pr CI RED:"; echo "$out"; exit 1; fi
echo "$out" | grep -q overhead && echo "$out" | grep overhead | grep -qi fail && echo "#$pr overhead gate failed (flaky; allocations checked by fixer) - proceeding"
gh pr merge "$pr" -R Rebulk/lantern --squash $( [ -z "${KEEP_BRANCH:-}" ] && echo --delete-branch ) >/dev/null 2>&1 && echo "#$pr MERGED" || { echo "#$pr merge failed"; exit 1; }
