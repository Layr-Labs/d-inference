#!/usr/bin/env bash
# Resolve workflow inputs before environment approval or access to signing keys.
set -euo pipefail

release_environment=${RELEASE_ENVIRONMENT:-prod}
validation_only=${RELEASE_VALIDATION_ONLY:-false}
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
  echo '::error::-dev tags are unsupported; use workflow_dispatch with environment=dev' >&2
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
  release_ref=${GITHUB_REF_NAME#v}
  release_version=${release_ref%-swift*}
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
