# Sourced by the focused check runners (Tests/*/run.sh). Run by hand, a runner
# compiles into a new temporary directory, runs its checks and removes the
# directory. CI runs it in two phases (scripts/cluster-test-plan.py
# focused lane): every runner's compile phase at the same time, then each
# runner's checks alone, in plan order, on the binaries its compile phase left.
#   CLUSTER_CHECK_PHASE=build  compile only; write the build directory's path
#                              to the file CLUSTER_CHECK_STATE names
#   CLUSTER_CHECK_PHASE=run    compile nothing; run the checks from the build
#                              directory that file names, then remove it

# check_build_directory NAME TEMPLATE: set the variable NAME to the build
# directory, a new `mktemp -d TEMPLATE` except in the run phase.
check_build_directory() {
  local check_directory
  case "${CLUSTER_CHECK_PHASE:-}" in
    "") check_directory="$(mktemp -d "$2")" ;;
    build)
      check_directory="$(mktemp -d "$2")"
      printf '%s\n' "$check_directory" > "${CLUSTER_CHECK_STATE:?CLUSTER_CHECK_STATE names the build directory file}"
      ;;
    run)
      check_directory="$(< "${CLUSTER_CHECK_STATE:?CLUSTER_CHECK_STATE names the build directory file}")"
      [[ -d "$check_directory" ]] || { echo "No build directory $check_directory: run the build phase first" >&2; exit 2; }
      ;;
    *) echo "CLUSTER_CHECK_PHASE must be build or run, not $CLUSTER_CHECK_PHASE" >&2; exit 2 ;;
  esac
  printf -v "$1" '%s' "$check_directory"
  # The run phase, and a run by hand, own the directory to the end.
  if [[ "${CLUSTER_CHECK_PHASE:-}" != build ]]; then trap "rm -rf '$check_directory'" EXIT; fi
}

# check_phases FUNCTION [ARGUMENT...]: call the runner's compile function, then
# stop in the build phase; skip it in the run phase.
check_phases() {
  case "${CLUSTER_CHECK_PHASE:-}" in
    "") "$@" ;;
    build) "$@"; exit 0 ;;
    run) ;;
  esac
}
