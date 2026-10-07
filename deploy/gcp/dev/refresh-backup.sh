# shellcheck shell=bash
# Dev only. seed-env.sh and swap.sh source this file. It is the one dev
# reading of the backup that deploy/gcp/prod/refresh-env.sh --apply makes: a
# copy of the env file at <env file>.bak.<UTC>, named on the last output line
# as "backup=<path>".

# refresh_backup_name_is_valid <env file> <path>: the path is
# <env file>.bak.<YYYYmmddTHHMMSSZ>.
refresh_backup_name_is_valid() {
    local suffix
    case "$2" in "$1".bak.*) suffix=${2#"$1".bak.} ;; *) return 1 ;; esac
    [[ "$suffix" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
}

# reported_refresh_backup <env file> <refresh --apply output>: prints the
# reported backup path when its name is valid and it is a regular file.
reported_refresh_backup() {
    local path=${2##*backup=}
    refresh_backup_name_is_valid "$1" "$path" && [ -f "$path" ] && [ ! -L "$path" ] || return 1
    printf '%s\n' "$path"
}
