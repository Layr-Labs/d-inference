#!/usr/bin/env bash
# Resolve workflow inputs after source verification, before access to signing keys.
set -euo pipefail

if [ -n "${RELEASE_RESUME_RUN_ID:-}" ]; then
  exec python3 scripts/provider-release-resume.py resolve
fi

release_environment=${RELEASE_ENVIRONMENT:-prod}
validation_only=${RELEASE_VALIDATION_ONLY:-false}
# The event alone selects dev for a branch push; push events carry no inputs.
if [ "${GITHUB_EVENT_NAME:-}" = push ] && [ "${GITHUB_REF_TYPE:-}" = branch ]; then
  if [ "${GITHUB_REF:-}" != refs/heads/master ]; then
    echo '::error::Branch pushes publish dev releases only from master' >&2
    exit 1
  fi
  release_environment=dev
  validation_only=false
  RELEASE_VERSION_OVERRIDE=
fi
case "$release_environment" in
  dev|prod) ;;
  *) echo '::error::Release environment must be dev or prod' >&2; exit 1 ;;
esac
case "$validation_only" in
  true|false) ;;
  *) echo '::error::validation_only must be true or false' >&2; exit 1 ;;
esac
if [ "$validation_only" = true ] && {
  [ "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ] || [ "$release_environment" != dev ];
}; then
  echo '::error::Signed validation requires workflow_dispatch with environment=dev' >&2
  exit 1
fi
if [ "$GITHUB_REF_TYPE" = tag ] && [[ "$GITHUB_REF_NAME" == *-dev.* ]]; then
  echo '::error::-dev tags are unsupported; dev releases come from master pushes or workflow_dispatch with environment=dev' >&2
  exit 1
fi
if [ "$release_environment" = prod ] && [ "$GITHUB_REF_TYPE" != tag ]; then
  echo '::error::Production publication requires a source-matching release tag' >&2
  exit 1
fi

if [ -n "${RELEASE_VERSION_OVERRIDE:-}" ]; then
  release_version=$RELEASE_VERSION_OVERRIDE
elif [ "$GITHUB_REF_TYPE" != tag ]; then
  release_version=$(awk -F'"' '/public static let version =/ { print $2 }' \
    provider-swift/Sources/ProviderCore/ProviderCore.swift)
else
  release_version=${GITHUB_REF_NAME#v}
fi
if [ "$release_environment" = dev ]; then
  # Every dev build carries a dev marker that SemVer orders by run number.
  if [[ ! "${GITHUB_RUN_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo '::error::A dev release requires GITHUB_RUN_NUMBER' >&2
    exit 1
  fi
  release_version="${release_version}-dev.${GITHUB_RUN_NUMBER}"
fi
# Validate before writing workflow outputs, including manual version overrides.
./scripts/check-release-version.sh "$release_version"
publish=true
[ "$validation_only" != true ] || publish=false
{
  echo "environment=$release_environment"
  echo "version=$release_version"
  echo "publish=$publish"
} >> "$GITHUB_OUTPUT"
echo "Resolved environment=$release_environment version=$release_version publish=$publish"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if [ "$publish" = true ]; then
    echo "### $release_environment provider release $release_version" >> "$GITHUB_STEP_SUMMARY"
  else
    echo "### $release_environment provider validation build $release_version (not published)" >> "$GITHUB_STEP_SUMMARY"
  fi
fi
