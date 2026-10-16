#!/usr/bin/env bash
# Resolve workflow inputs after source verification, before access to signing keys.
set -euo pipefail

if [ -n "${RELEASE_RESUME_RUN_ID:-}" ]; then
  exec python3 scripts/provider-release-resume.py resolve
fi

release_environment=${RELEASE_ENVIRONMENT:-prod}
validation_only=${RELEASE_VALIDATION_ONLY:-false}
# A master push publishes both a dev and a staging release (DBLM-771). The
# caller routes one lane per environment and passes RELEASE_ENVIRONMENT; the
# push event itself still carries no dispatch inputs, so a run with a missing or
# prod environment on a branch push is a misconfiguration and must fail closed.
# A push never selects prod, so the production signing identity stays tag-gated.
if [ "${GITHUB_EVENT_NAME:-}" = push ] && [ "${GITHUB_REF_TYPE:-}" = branch ]; then
  if [ "${GITHUB_REF:-}" != refs/heads/master ]; then
    echo '::error::Branch pushes publish releases only from master' >&2
    exit 1
  fi
  case "$release_environment" in
    dev|staging) ;;
    *) echo "::error::Branch pushes publish dev or staging only (got ${release_environment:-<empty>})" >&2; exit 1 ;;
  esac
  validation_only=false
  RELEASE_VERSION_OVERRIDE=
fi
# dev, prod and staging are the three environments (DBLM-771). prod requires a
# source-matching tag; dev and staging come from a master push or a dispatch.
case "$release_environment" in
  dev|prod|staging) ;;
  *) echo '::error::Release environment must be dev, prod or staging' >&2; exit 1 ;;
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
if [ "$GITHUB_REF_TYPE" = tag ] && [[ "$GITHUB_REF_NAME" == *-staging.* ]]; then
  echo '::error::-staging tags are unsupported; staging releases come from workflow_dispatch with environment=staging' >&2
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
if [ "$release_environment" = staging ]; then
  # Every staging build carries a staging marker that SemVer orders by run number.
  if [[ ! "${GITHUB_RUN_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo '::error::A staging release requires GITHUB_RUN_NUMBER' >&2
    exit 1
  fi
  release_version="${release_version}-staging.${GITHUB_RUN_NUMBER}"
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
