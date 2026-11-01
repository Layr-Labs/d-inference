#!/usr/bin/env bash
# Resolve workflow inputs after source verification, before access to signing keys.
set -euo pipefail

if [ -n "${RELEASE_RESUME_RUN_ID:-}" ]; then
  exec python3 scripts/provider-release-resume.py resolve
fi

release_environment=${RELEASE_ENVIRONMENT:-prod}
validation_only=${RELEASE_VALIDATION_ONLY:-false}
# A master push publishes a staging release only (DBLM-771), and a dev push
# publishes a dev release only (DevNet runs the d-inference dev branch). The
# caller routes the lane and passes RELEASE_ENVIRONMENT; the push event itself
# still carries no dispatch inputs, so any other environment on a branch push is
# a misconfiguration and must fail closed. A push never selects prod, so the
# production signing identity stays tag-gated.
dev_push=false
if [ "${GITHUB_EVENT_NAME:-}" = push ] && [ "${GITHUB_REF_TYPE:-}" = branch ]; then
  case "${GITHUB_REF:-}" in
    refs/heads/master)
      case "$release_environment" in
        staging) ;;
        *) echo "::error::Master pushes publish staging only (got ${release_environment:-<empty>})" >&2; exit 1 ;;
      esac
      ;;
    refs/heads/dev)
      case "$release_environment" in
        dev) dev_push=true ;;
        *) echo "::error::Dev branch pushes publish dev only (got ${release_environment:-<empty>})" >&2; exit 1 ;;
      esac
      ;;
    *) echo '::error::Branch pushes publish releases only from master or dev' >&2; exit 1 ;;
  esac
  validation_only=false
  RELEASE_VERSION_OVERRIDE=
fi
# dev, prod and staging are the three environments (DBLM-771). prod requires a
# source-matching tag; staging comes from a master push or a dispatch; dev comes
# from a dev push, or from master only as a signed validation build that is
# never published.
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
if [ "$release_environment" = dev ] && [ "$validation_only" != true ] && [ "$dev_push" != true ]; then
  echo '::error::A dev release requires a push to the dev branch; master builds dev only as a validation build' >&2
  exit 1
fi
if [ "$GITHUB_REF_TYPE" = tag ] && [[ "$GITHUB_REF_NAME" == *-dev.* ]]; then
  echo '::error::-dev tags are unsupported; dev releases come from dev branch pushes' >&2
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
  if [ "$dev_push" = true ]; then
    # A dev push stamps -dev.branch.N, apart from the -dev.N validation builds.
    release_version="${release_version}-dev.branch.${GITHUB_RUN_NUMBER}"
  else
    release_version="${release_version}-dev.${GITHUB_RUN_NUMBER}"
  fi
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
