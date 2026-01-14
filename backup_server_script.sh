#!/bin/bash
set -euo pipefail

# ===================== CONFIG =====================
BACKUP_USER="backups"
REMOTE_HOST="127.0.0.1"
REMOTE_DIR="/home/backups/remote_backup"

# ===================== CREATE REMOTE USER & DIR =====================
if ! id "$BACKUP_USER" &>/dev/null; then
    echo "Creating remote backup user: $BACKUP_USER"
    sudo useradd -m "$BACKUP_USER"
fi

echo "Creating remote backup directory: $REMOTE_DIR"
sudo mkdir -p "$REMOTE_DIR"
sudo chown "$BACKUP_USER":"$BACKUP_USER" "$REMOTE_DIR"

# ===================== SSH KEYS =====================
SSH_KEY="$HOME/.ssh/backup_key"
if [[ ! -f "$SSH_KEY" ]]; then
    echo "Generating SSH key..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N ""
fi

echo "Copying SSH key to remote user..."
ssh-copy-id -i "$SSH_KEY.pub" "$BACKUP_USER@$REMOTE_HOST"

echo "Testing SSH connection..."
ssh -i "$SSH_KEY" "$BACKUP_USER@$REMOTE_HOST" "echo SSH OK"

# ===================== LOCAL FOLDERS =====================
echo "Creating local backup directories..."
mkdir -p "$LOCAL_BACKUP_ROOT" "$LOG_PATH"
for d in "${INPUT_DIRS[@]}"; do
    mkdir -p "$d"
done

echo "Setup complete. You can now run ./backup.sh"
