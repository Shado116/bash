#!/bin/bash
set -euo pipefail

# LOAD CONFIG
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${BASE_DIR}/config.conf"

[[ ! -f "$CONFIG_FILE" ]] && echo ">>! $(date '+%F %T') Config file not found" && exit 1
source "$CONFIG_FILE"

# LOGGING
PERIOD_TAG="$(date '+%Y-%m')"
mkdir -p "$LOG_PATH"
LOG_FILE="${LOG_PATH}/${PERIOD_TAG}.log"
step=0
TOTAL_STEPS=10

log() {
    step=$((step+1))
    echo ">> [${step}/${TOTAL_STEPS}] $(date '+%F %T') $1" | tee -a "$LOG_FILE"
}

log_err() {
    echo ">>! $(date '+%F %T') $1" | tee -a "$LOG_FILE"
}

# LOCK
acquire_lock() {
    [[ -e "$RUNTIME_LOCK" ]] && log_err "Backup already running" && exit 0
    touch "$RUNTIME_LOCK"
    trap 'rm -f "$RUNTIME_LOCK"' EXIT
}

# DISK SPACE CHECK
check_disk_space() {
    local target="$1"
    local required_gb=1
    local free_gb
    free_gb=$(df -BG "$target" | awk 'NR==2 {gsub("G",""); print $4}')
    if (( free_gb < required_gb )); then
        log_err "Not enough disk space on $target: ${free_gb}G"
        exit 1
    fi
}

# PREPARE STRUCTURE
prepare_snapshot() {
    SNAPSHOT_ROOT="${BACKUP_ROOT}/${CYCLE_NAME}_${PERIOD_TAG}/snapshot"
    DIRS_BACKUP="${SNAPSHOT_ROOT}/dirs"
    REPOS_BACKUP="${SNAPSHOT_ROOT}/repos"

    mkdir -p "$DIRS_BACKUP" "$REPOS_BACKUP" "$ARCHIVE_STORE" "$WORK_TMP"
}

# REMOTE CHECK
check_remote() {
    ping -c 1 "$REMOTE_ADDR" &>/dev/null || { log_err "Remote unreachable"; exit 1; }
    ssh "${REMOTE_LOGIN}@${REMOTE_ADDR}" "true" &>/dev/null || { log_err "SSH failed"; exit 1; }
}

# HELPERS
is_git_repo() {
    [[ -d "$1/.git" || -f "$1/.git" ]]
}

sanitize_name() {
    # Replace spaces with underscores
    echo "${1// /_}"
}

backup_repo() {
    local src="$1"
    local name
    name="$(basename "$src")"
    name=$(sanitize_name "$name")
    local dest="${REPOS_BACKUP}/${name}.git"

    if [[ -d "$dest/.git" ]]; then
        log "Updating git repository $name"
        git -C "$dest" pull --ff-only >>"$LOG_FILE" 2>&1 || log_err "git pull failed: $name"
    else
        log "Cloning git repository $name"
        git clone "$src" "$dest" >>"$LOG_FILE" 2>&1 || log_err "git clone failed: $name"
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
        "${RSYNC_FILTERS[@]}" \
        "$src/" "$dest/" >>"$LOG_FILE" 2>&1 \
        || log_err "Dir copy warnings: $src"
}

# PROCESS INPUT
process_input_dirs() {
    for ROOT in "${INPUT_DIRS[@]}"; do
        [[ ! -r "$ROOT" ]] && log_err "No permissions: $ROOT" && continue
        log "Processing root directory: $ROOT"

        backup_dir "$ROOT"

        # Only first-level children for git detection
        for CHILD in "$ROOT"/*; do
            [[ ! -d "$CHILD" ]] && continue
            if is_git_repo "$CHILD"; then
                backup_repo "$CHILD"
            fi
        done
    done

    for REPO in "${REPOSITORIES[@]}"; do
        [[ ! -d "$REPO" ]] && log_err "Repository not found: $REPO" && continue
        backup_repo "$REPO"
    done
}

# ARCHIVE
archive_old() {
    log "Archiving old snapshots"
    find "$BACKUP_ROOT" -maxdepth 1 -type d -name "${CYCLE_NAME}_*" \
        ! -name "${CYCLE_NAME}_${PERIOD_TAG}" | while read -r OLD; do
            local archive_name
            archive_name="$(basename "$OLD").tar.gz"
            log "Archiving $OLD -> $archive_name"
            tar -czf "${WORK_TMP}/${archive_name}" -C "$OLD" . >>"$LOG_FILE" 2>&1 \
                || log_err "Archive creation failed: $OLD"
            mv "${WORK_TMP}/${archive_name}" "$ARCHIVE_STORE/"
            rm -rf "$OLD"
        done
}

# REMOTE PUSH
push_remote() {
    log "Sending archives to remote host"
    rsync -av "$ARCHIVE_STORE/" \
        "${REMOTE_LOGIN}@${REMOTE_ADDR}:${REMOTE_TARGET_DIR}/" >>"$LOG_FILE" 2>&1 \
        || log_err "Remote transfer warnings"
}

# MAIN
log "BACKUP START"
acquire_lock
check_disk_space "$BACKUP_ROOT"
prepare_snapshot
check_remote
process_input_dirs
archive_old
push_remote
log "BACKUP END"
