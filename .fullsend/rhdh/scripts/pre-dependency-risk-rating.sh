#!/usr/bin/env bash
# Pre-script: resolve the PR, skip closed/non-PR targets, fetch metadata for
# the sandbox. Runs on the trusted runner before the sandbox starts.
set -euo pipefail

WORKSPACE="/tmp/workspace"
mkdir -p "${WORKSPACE}"

_TOKEN="${REVIEW_TOKEN:-${GH_TOKEN:-}}"
if [[ -n "${_TOKEN}" ]]; then
  echo "::add-mask::${_TOKEN}"
  export GH_TOKEN="${_TOKEN}"
fi

# Dispatch may set PR_NUMBER, ISSUE_NUMBER (PR comments), GITHUB_PR_URL,
# GITHUB_ISSUE_URL, and/or ISSUE_URL. Prefer an explicit PR URL, then derive.
ISSUE_URL="${ISSUE_URL:-${GITHUB_PR_URL:-${GITHUB_ISSUE_URL:-}}}"
REPO_FULL_NAME="${REPO_FULL_NAME:-}"
PR_NUMBER="${PR_NUMBER:-${ISSUE_NUMBER:-}}"

if [[ -z "${ISSUE_URL}" && -n "${REPO_FULL_NAME}" && -n "${PR_NUMBER}" ]]; then
  ISSUE_URL="https://github.com/${REPO_FULL_NAME}/pull/${PR_NUMBER}"
fi

if [[ -z "${ISSUE_URL}" ]]; then
  echo "::error::ISSUE_URL (or GITHUB_PR_URL / PR_NUMBER+REPO_FULL_NAME) is required"
  exit 1
fi

if [[ "${ISSUE_URL}" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/([0-9]+)([?#].*)?$ ]]; then
  URL_REPO="${BASH_REMATCH[1]}"
  URL_PR="${BASH_REMATCH[2]}"
elif [[ "${ISSUE_URL}" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/issues/([0-9]+)([?#].*)?$ ]]; then
  URL_REPO="${BASH_REMATCH[1]}"
  URL_PR="${BASH_REMATCH[2]}"
else
  echo "::error::ISSUE_URL is not a GitHub issue or pull request URL: ${ISSUE_URL}"
  exit 1
fi

if [[ -z "${REPO_FULL_NAME}" ]]; then
  REPO_FULL_NAME="${URL_REPO}"
elif [[ "${REPO_FULL_NAME}" != "${URL_REPO}" ]]; then
  echo "::error::REPO_FULL_NAME (${REPO_FULL_NAME}) does not match URL repo (${URL_REPO})"
  exit 1
fi

if [[ -z "${PR_NUMBER}" ]]; then
  PR_NUMBER="${URL_PR}"
elif [[ "${PR_NUMBER}" != "${URL_PR}" ]]; then
  echo "::error::PR_NUMBER (${PR_NUMBER}) does not match URL number (${URL_PR})"
  exit 1
fi

if [[ ! "${PR_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::PR_NUMBER must be a positive integer, got: '${PR_NUMBER}'"
  exit 1
fi

ISSUE_URL="https://github.com/${REPO_FULL_NAME}/pull/${PR_NUMBER}"

# Expose normalized values to later steps / host_files expansion.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "ISSUE_URL=${ISSUE_URL}"
    echo "GITHUB_PR_URL=${ISSUE_URL}"
    echo "REPO_FULL_NAME=${REPO_FULL_NAME}"
    echo "PR_NUMBER=${PR_NUMBER}"
  } >> "${GITHUB_ENV}"
fi

echo "::notice::Risk-rating target: ${ISSUE_URL}"

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "::error::GH_TOKEN or REVIEW_TOKEN is required to fetch PR metadata"
  exit 1
fi

# Confirm this number is actually a pull request (issue comments on PRs share
# the issues API). Skip cleanly when it is a plain issue.
if ! gh pr view "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" --json number >/dev/null 2>&1; then
  echo "Not an openable pull request: ${REPO_FULL_NAME}#${PR_NUMBER}"
  exit 78
fi

PR_JSON="$(gh pr view "${PR_NUMBER}" --repo "${REPO_FULL_NAME}" \
  --json number,url,title,body,state,baseRefOid,headRefOid,files,labels)"

PR_STATE="$(jq -r '.state' <<<"${PR_JSON}")"
if [[ "${PR_STATE}" != "OPEN" ]]; then
  echo "::notice::PR #${PR_NUMBER} is ${PR_STATE} — skipping risk rating"
  exit 78
fi

# Filenames only in JSON — never the lockfile patch (can be multiple MB).
# Manifest blobs are fetched below so the sandbox never calls GitHub.
jq '{
  number,
  url,
  title,
  body,
  state,
  base_sha: .baseRefOid,
  head_sha: .headRefOid,
  files: [.files[].path],
  labels: [.labels[].name]
}' <<<"${PR_JSON}" > "${WORKSPACE}/pr-context.json"

BASE_SHA="$(jq -r '.base_sha' "${WORKSPACE}/pr-context.json")"
HEAD_SHA="$(jq -r '.head_sha' "${WORKSPACE}/pr-context.json")"

# Skill Mode C would fetch these via GitHub from the sandbox. OpenShell has
# no DNS; do it here instead (same blobs → compare-manifests.ts locally).
PR_DATA="${WORKSPACE}/pr-data"
mkdir -p "${PR_DATA}/base" "${PR_DATA}/head"
cp "${WORKSPACE}/pr-context.json" "${PR_DATA}/pr-context.json"

is_manifest_path() {
  case "$(basename "$1")" in
    package.json|yarn.lock|package-lock.json|npm-shrinkwrap.json) return 0 ;;
    *) return 1 ;;
  esac
}

fetch_raw() {
  local ref="$1" relpath="$2" dest="$3"
  mkdir -p "$(dirname "${dest}")"
  if gh api -H "Accept: application/vnd.github.raw" \
    "/repos/${REPO_FULL_NAME}/contents/${relpath}?ref=${ref}" \
    > "${dest}" 2>/dev/null; then
    return 0
  fi
  rm -f "${dest}"
  return 1
}

CHANGED_FILES=()
while IFS= read -r _f; do
  [[ -n "${_f}" ]] && CHANGED_FILES+=("${_f}")
done < <(jq -r '.files[]?' "${WORKSPACE}/pr-context.json")

FETCHED=0
declare -A PATHS=()
for relpath in "${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}"; do
  [[ -z "${relpath}" ]] && continue
  if is_manifest_path "${relpath}"; then
    PATHS["${relpath}"]=1
  fi
  case "$(basename "${relpath}")" in
    yarn.lock|package-lock.json|npm-shrinkwrap.json)
      # Root lockfiles dirname to "."; the Contents API rejects "./package.json".
      dir="$(dirname "${relpath}")"
      if [[ "${dir}" == "." ]]; then
        PATHS["package.json"]=1
      else
        PATHS["${dir}/package.json"]=1
      fi
      ;;
  esac
done

if ((${#PATHS[@]} > 0)); then
  for relpath in "${!PATHS[@]}"; do
    if fetch_raw "${BASE_SHA}" "${relpath}" "${PR_DATA}/base/${relpath}"; then
      FETCHED=$((FETCHED + 1))
    fi
    if fetch_raw "${HEAD_SHA}" "${relpath}" "${PR_DATA}/head/${relpath}"; then
      FETCHED=$((FETCHED + 1))
    fi
  done
fi

fetch_raw "${HEAD_SHA}" ".dependency-risk.yaml" "${PR_DATA}/target-config.yaml" || true
fetch_raw "${HEAD_SHA}" "backstage.json" "${PR_DATA}/backstage.json" || true

tar -C "${PR_DATA}" -cf "${WORKSPACE}/pr-data.tar" .
echo "Wrote ${WORKSPACE}/pr-context.json and pr-data.tar (${FETCHED} manifest blobs)"
echo "PR_NUMBER=${PR_NUMBER}"
echo "REPO_FULL_NAME=${REPO_FULL_NAME}"
echo "ISSUE_URL=${ISSUE_URL}"
