#!/usr/bin/env bash
# Open one fix PR per fixable finding, using the CALLER's GITHUB_TOKEN.
#
# RootingLabs never authenticates to the client's GitHub: this runs inside the
# client's own workflow, applies the engine's fix_before -> fix_after anchors to
# the checked-out repo, and opens PRs with the workflow's own token. The repo
# must already be checked out (actions/checkout) and the job must grant
# `contents: write` and `pull-requests: write`.
set -euo pipefail

API_URL="${RL_API_URL:-https://rootinglabs.com}"
API_URL="${API_URL%/}"
TOKEN="${RL_TOKEN:?RL_TOKEN is required}"
SCAN_ID="${RL_SCAN_ID:?RL_SCAN_ID is required}"
ACTION_DIR="${ACTION_DIR:?ACTION_DIR is required}"
MAX="${RL_FIX_PRS_MAX:-10}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "RootingLabs: no git checkout found — add actions/checkout before this step." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
curl -fsS -H "Authorization: Bearer ${TOKEN}" "${API_URL}/v1/scans/${SCAN_ID}/fixes" -o "${work}/fixes.json"
total=$(jq '.fixes | length' "${work}/fixes.json")
if [[ "${total}" -eq 0 ]]; then
  echo "RootingLabs: no fixable findings for scan ${SCAN_ID}."
  exit 0
fi

base="${RL_FIX_BASE:-}"
[[ -z "${base}" ]] && base="$(git rev-parse --abbrev-ref HEAD)"
git config user.name "rootinglabs-bot"
git config user.email "bot@rootinglabs.com"

opened=0
for i in $(seq 0 $((total - 1))); do
  [[ "${opened}" -ge "${MAX}" ]] && break
  jq ".fixes[${i}]" "${work}/fixes.json" >"${work}/fix.json"
  fid=$(jq -r '.finding_id' "${work}/fix.json")
  title=$(jq -r '.title' "${work}/fix.json")
  branch="rootinglabs/fix-${fid:0:8}"

  git checkout -B "${branch}" "${base}" >/dev/null 2>&1
  changed=$(python3 "${ACTION_DIR}/apply_fix.py" "${work}/fix.json" || true)
  if [[ -z "${changed}" ]]; then
    echo "RootingLabs: skip ${fid} (anchors not found in current code)"
    git checkout "${base}" >/dev/null 2>&1
    continue
  fi

  git add -A
  jq -r '.fix_pr_body' "${work}/fix.json" >"${work}/body.md"
  git commit -q -F "${work}/body.md" || {
    git checkout "${base}" >/dev/null 2>&1
    continue
  }
  git push -f origin "${branch}" >/dev/null 2>&1
  if GH_TOKEN="${GITHUB_TOKEN}" gh pr create \
    --base "${base}" --head "${branch}" \
    --title "Fix: ${title}" --body-file "${work}/body.md" >/dev/null 2>&1; then
    echo "RootingLabs: opened fix PR for ${fid} (${branch})"
    opened=$((opened + 1))
  else
    echo "RootingLabs: PR for ${branch} may already exist; branch pushed."
  fi
  git checkout "${base}" >/dev/null 2>&1
done

echo "RootingLabs: ${opened} fix PR(s) opened."
