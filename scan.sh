#!/usr/bin/env bash
# RootingLabs CI runner.
#
# Creates a scan, (optionally) waits for it to finish, downloads the SARIF, and
# exits non-zero when a finding meets or exceeds the `fail-on` severity. It uses
# only endpoints that the API already exposes:
#   POST /v1/scans                 create + queue
#   GET  /v1/scans/{id}            poll status + severities
#   GET  /v1/scans/{id}/sarif      SARIF 2.1.0 for upload
#
# Portable across GitHub Actions and GitLab CI: everything is read from env.
set -euo pipefail

API_URL="${RL_API_URL:-https://rootinglabs.com}"
TOKEN="${RL_TOKEN:?RL_TOKEN is required}"
TARGET="${RL_TARGET:?RL_TARGET is required}"
SCAN_MODE="${RL_SCAN_MODE:-standard}"
FAIL_ON="${RL_FAIL_ON:-high}"
SARIF_FILE="${RL_SARIF_FILE:-rootinglabs.sarif}"
WAIT="${RL_WAIT:-true}"
TIMEOUT_MINUTES="${RL_TIMEOUT_MINUTES:-60}"

API_URL="${API_URL%/}"
auth=(-H "Authorization: Bearer ${TOKEN}")
json=(-H "Content-Type: application/json")

# GitHub Actions exposes $GITHUB_OUTPUT; elsewhere we no-op.
emit() { if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1=$2" >>"${GITHUB_OUTPUT}"; fi; }

severity_rank() {
  case "$1" in
    critical) echo 4 ;; high) echo 3 ;; medium) echo 2 ;; low) echo 1 ;; *) echo 0 ;;
  esac
}

echo "RootingLabs: queueing ${SCAN_MODE} scan of ${TARGET}"
create_body=$(jq -nc --arg t "${TARGET}" --arg m "${SCAN_MODE}" \
  '{target:$t, scan_mode:$m, instructions:""}')
create=$(curl -fsS "${auth[@]}" "${json[@]}" -d "${create_body}" "${API_URL}/v1/scans")
scan_id=$(echo "${create}" | jq -r '.id')
if [[ -z "${scan_id}" || "${scan_id}" == "null" ]]; then
  echo "RootingLabs: failed to create scan" >&2
  echo "${create}" >&2
  exit 1
fi
echo "RootingLabs: scan ${scan_id} queued"
emit "scan-id" "${scan_id}"
emit "sarif-file" "${SARIF_FILE}"

if [[ "${WAIT}" != "true" ]]; then
  echo "RootingLabs: wait=false, leaving scan ${scan_id} running"
  emit "status" "queued"
  exit 0
fi

deadline=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
status="queued"
while :; do
  detail=$(curl -fsS "${auth[@]}" "${API_URL}/v1/scans/${scan_id}") || true
  status=$(echo "${detail}" | jq -r '.status // "queued"')
  echo "RootingLabs: scan ${scan_id} status=${status}"
  case "${status}" in
    completed|failed|stopped) break ;;
  esac
  if (( $(date +%s) > deadline )); then
    echo "RootingLabs: timed out after ${TIMEOUT_MINUTES} min (status=${status})" >&2
    emit "status" "${status}"
    exit 1
  fi
  sleep 15
done
emit "status" "${status}"

echo "RootingLabs: downloading SARIF to ${SARIF_FILE}"
curl -fsS "${auth[@]}" "${API_URL}/v1/scans/${scan_id}/sarif" -o "${SARIF_FILE}"

# Record this run on the Analyses timeline (best-effort; never fails the build).
run_detail=$(curl -fsS "${auth[@]}" "${API_URL}/v1/scans/${scan_id}" 2>/dev/null || echo '{}')
run_findings=$(echo "${run_detail}" | jq '[.findings[]?] | length' 2>/dev/null || echo 0)
run_status="completed"
[[ "${status}" == "completed" ]] || run_status="failed"
curl -fsS "${auth[@]}" "${json[@]}" -X POST \
  -d "$(jq -nc --arg s "${TARGET}" --arg st "${run_status}" --argjson n "${run_findings:-0}" \
    '{family:"web_analysis", status:$st, source:$s, findings_count:$n, detail:"scan-action run"}')" \
  "${API_URL}/v1/analyses" >/dev/null 2>&1 || true

if [[ "${status}" != "completed" ]]; then
  echo "RootingLabs: scan did not complete (status=${status})" >&2
  exit 1
fi

if [[ "${FAIL_ON}" == "none" ]]; then
  echo "RootingLabs: fail-on=none, not gating the build"
  exit 0
fi

detail=$(curl -fsS "${auth[@]}" "${API_URL}/v1/scans/${scan_id}")
threshold=$(severity_rank "${FAIL_ON}")
worst=0
breaching=0
while read -r sev; do
  [[ -z "${sev}" ]] && continue
  rank=$(severity_rank "${sev}")
  (( rank > worst )) && worst="${rank}"
  (( rank >= threshold )) && breaching=$(( breaching + 1 ))
done < <(echo "${detail}" | jq -r '.findings[].severity // empty')

if (( breaching > 0 )); then
  echo "RootingLabs: ${breaching} finding(s) at or above '${FAIL_ON}' — failing the build." >&2
  echo "RootingLabs: see the findings in the Security tab or your dashboard." >&2
  exit 2
fi
echo "RootingLabs: no finding at or above '${FAIL_ON}'. Build passes."
