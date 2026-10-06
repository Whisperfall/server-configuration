#!/usr/bin/env bash

set -e

CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d-%H%M%S)"

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo $0"
    exit 1
fi

echo "Backing up sshd_config..."
cp "$CONFIG" "$BACKUP"

set_ssh_option() {
    KEY="$1"
    VALUE="$2"

    if grep -Eq "^[[:space:]#]*${KEY}[[:space:]]+" "$CONFIG"; then
        sed -i -E "s|^[[:space:]#]*${KEY}[[:space:]]+.*|${KEY} ${VALUE}|" "$CONFIG"
    else
        echo "${KEY} ${VALUE}" >> "$CONFIG"
    fi
}

set_ssh_option "PasswordAuthentication" "no"
set_ssh_option "KbdInteractiveAuthentication" "no"
set_ssh_option "PubkeyAuthentication" "yes"
set_ssh_option "PermitRootLogin" "prohibit-password"

echo
echo "Checking SSH configuration..."

if sshd -t; then
    echo "SSH configuration OK."
else
    echo "ERROR: Invalid SSH configuration."
    echo "Restoring backup..."
    cp "$BACKUP" "$CONFIG"
    exit 1
fi

echo
echo "Configured values:"
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin) '

echo
echo "Restarting SSH..."

if systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl restart ssh
elif systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl restart sshd
else
    echo "Could not find SSH service."
    exit 1
fi

echo
echo "Done."
echo "Backup: $BACKUP"
echo "IMPORTANT: Keep this SSH session open and test login from another terminal."
