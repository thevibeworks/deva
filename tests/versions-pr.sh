#!/usr/bin/env bash
# Hermetic test for scripts/versions-pr.sh: real git against a scratch
# bare origin, fake gh. The user checkout (branch, dirty files) must
# come out untouched — the commit happens in a throwaway worktree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="$(mktemp -d)"
FAKE_BIN="$TMP_ROOT/bin"
GH_LOG="$TMP_ROOT/gh.log"
mkdir -p "$FAKE_BIN"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "$1" >&2
    exit 1
}

# GH_PR_LIST_URL switches the open-PR lookup between "none" and "exists".
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
case "${1:-} ${2:-}" in
"pr list")   echo "${GH_PR_LIST_URL:-}" ;;
"pr create") echo "https://github.com/thevibeworks/deva/pull/999" ;;
*)
    echo "unexpected gh invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

# ───── scratch origin: bare repo seeded with the real versions.env ─────
ORIGIN="$TMP_ROOT/origin.git"
SEED="$TMP_ROOT/seed"
git init --quiet --bare --initial-branch=main "$ORIGIN"
git init --quiet --initial-branch=main "$SEED"
git -C "$SEED" config user.name test
git -C "$SEED" config user.email test@test
cp "$REPO_ROOT/versions.env" "$SEED/versions.env"
git -C "$SEED" add versions.env
git -C "$SEED" commit --quiet -m "seed"
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push --quiet origin main

# ───── user checkout: on a WIP branch with dirty state ─────
CLONE="$TMP_ROOT/clone"
git clone --quiet "$ORIGIN" "$CLONE"
git -C "$CLONE" config user.name test
git -C "$CLONE" config user.email test@test
git -C "$CLONE" switch --quiet -c my-wip
echo junk >"$CLONE/wip.txt"

PR_SCRIPT="$REPO_ROOT/scripts/versions-pr.sh"

run_pr() {
    PATH="$FAKE_BIN:$PATH" \
    GH_LOG="$GH_LOG" \
    GH_PR_LIST_URL="${GH_PR_LIST_URL:-}" \
    REPO_ROOT="$CLONE" \
    bash "$PR_SCRIPT" 2>&1
}

# ───── 1. pins match upstream: no-op, no branch pushed ─────
out="$(run_pr)" || fail "no-op run must exit 0: $out"
grep -F -- "Pins already match" <<<"$out" >/dev/null || fail "expected no-op message, got: $out"
if git -C "$ORIGIN" show-ref --verify --quiet refs/heads/chore/version-pins-refresh; then
    fail "no-op run must not push a branch"
fi

# ───── 2. comment-only drift: skip, no branch pushed ─────
echo "# trailing comment for drift test" >>"$CLONE/versions.env"
out="$(run_pr)" || fail "comment-drift run must exit 0: $out"
grep -F -- "no pin changed; skipping PR" <<<"$out" >/dev/null || fail "expected comment-drift skip, got: $out"
if git -C "$ORIGIN" show-ref --verify --quiet refs/heads/chore/version-pins-refresh; then
    fail "comment-only drift must not push a branch"
fi
git -C "$CLONE" checkout --quiet versions.env

# ───── 3. real bump: branch pushed, commit body lists bumps, PR created ─────
sed -i \
    -e 's/^CLAUDE_CODE_VERSION=.*/CLAUDE_CODE_VERSION=9.9.9/' \
    -e 's/^COPILOT_API_VERSION=.*/COPILOT_API_VERSION=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' \
    "$CLONE/versions.env"

out="$(run_pr)" || fail "bump run failed: $out"
grep -F -- "Opened pin PR" <<<"$out" >/dev/null || fail "expected PR-created message, got: $out"

git -C "$ORIGIN" show-ref --verify --quiet refs/heads/chore/version-pins-refresh || \
    fail "bump branch missing on origin"

pushed_pins="$(git -C "$ORIGIN" show refs/heads/chore/version-pins-refresh:versions.env)"
grep -qx "CLAUDE_CODE_VERSION=9.9.9" <<<"$pushed_pins" || fail "pushed pins missing bumped claude-code"

commit_msg="$(git -C "$ORIGIN" log -1 --format=%B refs/heads/chore/version-pins-refresh)"
grep -qx "chore(versions): refresh agent CLI pins" <<<"$(head -1 <<<"$commit_msg")" || \
    fail "wrong commit subject: $commit_msg"
grep -F -- "claude-code" <<<"$commit_msg" | grep -F -- "-> 9.9.9" >/dev/null || \
    fail "commit body missing claude-code bump: $commit_msg"
# 40-hex values are shortened for humans
grep -F -- "copilot-api" <<<"$commit_msg" | grep -F -- "-> deadbee" >/dev/null || \
    fail "commit body missing shortened copilot hash: $commit_msg"
if grep -F -- "deadbeefdeadbeef" <<<"$commit_msg" >/dev/null; then
    fail "commit body must not carry full 40-char hashes"
fi

grep -E -- "^pr create .*--base main .*--head chore/version-pins-refresh" "$GH_LOG" >/dev/null || \
    fail "gh pr create missing or malformed: $(cat "$GH_LOG")"

# ───── 4. rerun with the PR already open: update branch, no second create ─────
: >"$GH_LOG"
out="$(GH_PR_LIST_URL="https://github.com/thevibeworks/deva/pull/999" run_pr)" || \
    fail "rerun with open PR failed: $out"
grep -F -- "already open" <<<"$out" >/dev/null || fail "expected already-open message, got: $out"
if grep -F -- "pr create" "$GH_LOG" >/dev/null; then
    fail "must not open a second PR when one is already open"
fi

# ───── user checkout untouched throughout ─────
[[ "$(git -C "$CLONE" branch --show-current)" == "my-wip" ]] || fail "user branch changed"
[[ -f "$CLONE/wip.txt" ]] || fail "user dirty file lost"
git -C "$CLONE" diff --quiet -- versions.env && fail "user versions.env edit lost"
[[ "$(git -C "$CLONE" worktree list | wc -l)" -eq 1 ]] || fail "leaked worktree in user checkout"

echo "versions-pr tests passed"
