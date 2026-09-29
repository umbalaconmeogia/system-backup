#!/usr/bin/env bash
#
# Forced command for the SSH key of the backup server.
# The backup server can only run the commands below, nothing else.
#
# ~/.ssh/authorized_keys:
#   command="/opt/webapp-backup/host/ssh-gate.sh /opt/webapp-backup/host/backup.conf",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... backup-server
#
# Allowed commands (sent by the backup server as SSH command):
#   backup <db|source|full>   Create a backup, print the file name.
#   list                      List finished backup files.
#   get <file name>           Output the content of a backup file (or its .sha256 file).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

CONFIG=${1:-$SCRIPT_DIR/backup.conf}

deny() {
    echo "ssh-gate: command not allowed" >&2
    exit 126
}

read -r -a WORDS <<< "${SSH_ORIGINAL_COMMAND:-}"

case "${WORDS[0]:-}" in
    backup)
        [ ${#WORDS[@]} -eq 2 ] || deny
        case "${WORDS[1]}" in
            db|source|full) exec "$SCRIPT_DIR/backup.sh" --config "$CONFIG" "${WORDS[1]}" ;;
            *) deny ;;
        esac
        ;;
    list)
        [ ${#WORDS[@]} -eq 1 ] || deny
        load_config "$CONFIG"
        [ -d "$BACKUP_DIR" ] || exit 0
        list_finished
        ;;
    get)
        [ ${#WORDS[@]} -eq 2 ] || deny
        load_config "$CONFIG"
        FILE=${WORDS[1]}
        [[ "$FILE" =~ ^[A-Za-z0-9._-]+\.zip(\.gpg)?(\.sha256)?$ ]] || deny
        [ "${FILE#"${PROJECT}_${ENV}_"}" != "$FILE" ] || deny
        [ -f "$BACKUP_DIR/${FILE%.sha256}.sha256" ] || { echo "ssh-gate: file not found" >&2; exit 1; }
        [ -f "$BACKUP_DIR/$FILE" ] || { echo "ssh-gate: file not found" >&2; exit 1; }
        exec cat -- "$BACKUP_DIR/$FILE"
        ;;
    *)
        deny
        ;;
esac
