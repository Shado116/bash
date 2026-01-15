#!/bin/bash
set -euo pipefail

#######################################
# LOAD CONFIG
#######################################
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${BASE_DIR}/config.conf"

[[ ! -f "$CONFIG_FILE" ]] && {
    echo ">>! $(date '+%F %T') Config file not found"
    exit 1
}

source "$CONFIG_FILE"

#######################################
# ARGUMENTS
#######################################
FORCE=0

usage() {
    echo "Usage: $0 [-force|--force]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -force|--force)
            FORCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

#######################################
# LOGGING
#######################################
PERIOD_TAG="$(date '+%Y-%m')"
mkdir -p "$LOG_PATH"
LOG_FILE="${LOG_PATH}/${PERIOD_TAG}.log"

step=0
TOTAL_STEPS=14

log() {
    step=$((step+1))
    echo ">> [${step}/${TOTAL_STEPS}] $(date '+%F %T') $1" | tee -a "$LOG_FILE"
}

log_err() {
    echo ">>! $(date '+%F %T') $1" | tee -a "$LOG_FILE"
}

#######################################
# LOCK
#######################################
acquire_lock() {
    if [[ -e "$RUNTIME_LOCK" ]]; then
        log_err "Backup already running"
        exit 0
    fi
    touch "$RUNTIME_LOCK"
    trap 'rm -f "$RUNTIME_LOCK"' EXIT
}

#######################################
# DISK SPACE CHECK
#######################################
check_disk_space() {
    local target="$1"
    local required_gb="${REQUIRED_FREE_GB:-1}"
    local free_gb

    free_gb=$(df -BG "$target" | awk 'NR==2 {gsub("G",""); print $4}')
    if (( free_gb < required_gb )); then
        log_err "Not enough disk space on $target (${free_gb}G free)"
        exit 1
    fi
}

#######################################
# PREPARE STRUCTURE
#######################################
prepare_snapshot() {
    SNAPSHOT_ROOT="${BACKUP_ROOT}/${CYCLE_NAME}_${PERIOD_TAG}/snapshot"
    DIRS_BACKUP="${SNAPSHOT_ROOT}/dirs"
    REPOS_BACKUP="${SNAPSHOT_ROOT}/repos"

    mkdir -p "$DIRS_BACKUP" "$REPOS_BACKUP" "$ARCHIVE_STORE" "$WORK_TMP"
}

#######################################
# REMOTE CHECK (SSH ONLY)
#######################################
check_remote() {
    log "Checking SSH connectivity to remote host"
    ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "${REMOTE_LOGIN}@${REMOTE_ADDR}" "true" &>/dev/null \
        || { log_err "SSH unreachable or authentication failed"; exit 1; }
}

#######################################
# HELPERS
#######################################
is_git_repo() {
    [[ -d "$1/.git" || -f "$1/.git" ]]
}

sanitize_name() {
    echo "${1// /_}"
}

#######################################
# BACKUP FUNCTIONS
#######################################
backup_repo() {
    local src="$1"
    local name
    name="$(basename "$src")"
    name=$(sanitize_name "$name")
    local dest="${REPOS_BACKUP}/${name}.git"

    if [[ -d "$dest/.git" ]]; then
        log "Updating git repository $name"
        git -C "$dest" pull --ff-only >>"$LOG_FILE" 2>&1 \
            || log_err "git pull failed: $name"
    else
        log "Cloning git repository $name"
        git clone "$src" "$dest" >>"$LOG_FILE" 2>&1 \
            || log_err "git clone failed: $name"
    fi
}

backup_dir() {
    local src="$1"
    local rel="${src#/}"
    local dest="${DIRS_BACKUP}/${rel}"
    dest=$(sanitize_name "$dest")

    mkdir -p "$dest"

    log "Syncing directory $src"
    rsync -a --delete --ignore-errors \
        --no-specials --no-devices \
        "${RSYNC_FILTERS[@]:-}" \
        "$src/" "$dest/" >>"$LOG_FILE" 2>&1 \
        || log_err "Dir copy warnings: $src"
}

#######################################
# PROCESS INPUT
#######################################
process_input_dirs() {
    for ROOT in "${INPUT_DIRS[@]}"; do
        if [[ ! -r "$ROOT" ]]; then
            log_err "No permissions: $ROOT"
            continue
        fi

        log "Processing root directory: $ROOT"
        backup_dir "$ROOT"

        for CHILD in "$ROOT"/*; do
            [[ ! -d "$CHILD" ]] && continue
            is_git_repo "$CHILD" && backup_repo "$CHILD"
        done
    done

    for REPO in "${REPOSITORIES[@]}"; do
        [[ ! -d "$REPO" ]] && {
            log_err "Repository not found: $REPO"
            continue
        }
        backup_repo "$REPO"
    done
}

#######################################
# ARCHIVING
#######################################
archive_old() {
    log "Archiving old snapshots"
    find "$BACKUP_ROOT" -maxdepth 1 -type d -name "${CYCLE_NAME}_*" \
        ! -name "${CYCLE_NAME}_${PERIOD_TAG}" | while read -r OLD; do
            local archive_name
            archive_name="$(basename "$OLD").tar.gz"

            log "Archiving $OLD"
            tar -czf "${WORK_TMP}/${archive_name}" -C "$OLD" . >>"$LOG_FILE" 2>&1 \
                || log_err "Archive failed: $OLD"

            mv "${WORK_TMP}/${archive_name}" "$ARCHIVE_STORE/"
            rm -rf "$OLD"
        done
}

create_current_archive() {
    local name="${CYCLE_NAME}_${PERIOD_TAG}_snapshot.tar.gz"

    log "Creating archive of current snapshot"
    tar -czf "${WORK_TMP}/${name}" -C "$SNAPSHOT_ROOT" . >>"$LOG_FILE" 2>&1 \
        || { log_err "Snapshot archive failed"; return 1; }

    mv "${WORK_TMP}/${name}" "$ARCHIVE_STORE/"
}

#######################################
# SEND LOGIC
#######################################
LAST_PUSH_FILE="${ARCHIVE_STORE}/.last_push"
SEND_INTERVAL_DAYS="${SEND_INTERVAL_DAYS:-30}"

send_due() {
    [[ ! -f "$LAST_PUSH_FILE" ]] && return 0
    local now last age
    now=$(date +%s)
    last=$(stat -c %Y "$LAST_PUSH_FILE")
    age=$(( (now - last) / 86400 ))
    (( age >= SEND_INTERVAL_DAYS ))
}

push_remote() {
    if [[ $FORCE -eq 0 ]] && ! send_due; then
        log "Remote push skipped (not due)"
        return 0
    fi

    [[ $FORCE -eq 1 ]] && log "Force enabled: pushing immediately"

    log "Sending archives to remote host"
    rsync -av "$ARCHIVE_STORE/" \
        "${REMOTE_LOGIN}@${REMOTE_ADDR}:${REMOTE_TARGET_DIR}/" >>"$LOG_FILE" 2>&1 \
        || { log_err "Remote transfer failed"; return 1; }

    touch "$LAST_PUSH_FILE"
}

#######################################
# MAIN
#######################################
log "BACKUP START"
acquire_lock
check_disk_space "$BACKUP_ROOT"
prepare_snapshot
check_remote
process_input_dirs
archive_old

[[ $FORCE -eq 1 ]] && create_current_archive

push_remote
log "BACKUP END"
