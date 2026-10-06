#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# SSH SAFE SETUP
#
# Ayarlar:
#   PasswordAuthentication no
#   KbdInteractiveAuthentication no
#   PubkeyAuthentication yes
#   PermitRootLogin prohibit-password
#
# Kullanım:
#   sudo bash setup-ssh.sh
#
# Farklı kullanıcıyı kontrol etmek için:
#   sudo TARGET_USER=altan bash setup-ssh.sh
# ============================================================

MAIN_CONFIG="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN_FILE="$DROPIN_DIR/00-ssh-hardening.conf"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/ssh-config-backup-$TIMESTAMP"

# ------------------------------------------------------------
# Root kontrolü
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Bu script root olarak çalıştırılmalı."
    echo "Kullanım: sudo bash $0"
    exit 1
fi

# ------------------------------------------------------------
# Kontrol edilecek kullanıcı
# ------------------------------------------------------------

if [[ -n "${TARGET_USER:-}" ]]; then
    SSH_USER="$TARGET_USER"
elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    SSH_USER="$SUDO_USER"
else
    SSH_USER="$(id -un)"
fi

if ! id "$SSH_USER" >/dev/null 2>&1; then
    echo "ERROR: Kullanıcı bulunamadı: $SSH_USER"
    exit 1
fi

USER_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"

if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    echo "ERROR: Kullanıcı home dizini bulunamadı."
    exit 1
fi

SSH_DIR="$USER_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

echo
echo "SSH kullanıcısı : $SSH_USER"
echo "Home            : $USER_HOME"
echo "authorized_keys : $AUTHORIZED_KEYS"
echo

# ------------------------------------------------------------
# SSH key kontrolü
# ------------------------------------------------------------

if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
    echo "ERROR: authorized_keys bulunamadı:"
    echo "$AUTHORIZED_KEYS"
    echo
    echo "Password login KAPATILMADI."
    exit 1
fi

if [[ ! -s "$AUTHORIZED_KEYS" ]]; then
    echo "ERROR: authorized_keys boş."
    echo
    echo "Password login KAPATILMADI."
    exit 1
fi

# En az bir SSH public key var mı?
if ! grep -Eq \
'^[[:space:]]*(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)' \
"$AUTHORIZED_KEYS"; then

    echo "ERROR: authorized_keys içinde geçerli görünen SSH public key bulunamadı."
    echo
    echo "Password login KAPATILMADI."
    exit 1
fi

echo "OK: Public key bulundu."

# ------------------------------------------------------------
# SSH dosya izinlerini düzelt
# ------------------------------------------------------------

mkdir -p "$SSH_DIR"

chown "$SSH_USER":"$(id -gn "$SSH_USER")" "$SSH_DIR"
chown "$SSH_USER":"$(id -gn "$SSH_USER")" "$AUTHORIZED_KEYS"

chmod 700 "$SSH_DIR"
chmod 600 "$AUTHORIZED_KEYS"

echo "OK: .ssh izinleri kontrol edildi."

# ------------------------------------------------------------
# sshd mevcut mu?
# ------------------------------------------------------------

if ! command -v sshd >/dev/null 2>&1; then
    echo "ERROR: sshd bulunamadı."
    exit 1
fi

if [[ ! -f "$MAIN_CONFIG" ]]; then
    echo "ERROR: $MAIN_CONFIG bulunamadı."
    exit 1
fi

# ------------------------------------------------------------
# Mevcut config geçerli mi?
# ------------------------------------------------------------

echo
echo "Mevcut SSH config kontrol ediliyor..."

if ! sshd -t; then
    echo
    echo "ERROR: Mevcut SSH configuration zaten hatalı."
    echo "Hiçbir değişiklik yapılmadı."
    exit 1
fi

echo "OK: Mevcut config geçerli."

# ------------------------------------------------------------
# Backup
# ------------------------------------------------------------

mkdir -p "$BACKUP_DIR"

cp -a "$MAIN_CONFIG" "$BACKUP_DIR/sshd_config"

if [[ -d "$DROPIN_DIR" ]]; then
    cp -a "$DROPIN_DIR" "$BACKUP_DIR/sshd_config.d" 2>/dev/null || true
fi

echo "OK: Backup alındı:"
echo "$BACKUP_DIR"

# ------------------------------------------------------------
# Rollback fonksiyonu
# ------------------------------------------------------------

rollback() {
    echo
    echo "!!! ROLLBACK YAPILIYOR !!!"

    cp -a "$BACKUP_DIR/sshd_config" "$MAIN_CONFIG"

    if [[ -d "$BACKUP_DIR/sshd_config.d" ]]; then
        rm -rf "$DROPIN_DIR"
        cp -a "$BACKUP_DIR/sshd_config.d" "$DROPIN_DIR"
    else
        rm -f "$DROPIN_FILE"
    fi

    echo "Eski SSH configuration geri yüklendi."
}

# ------------------------------------------------------------
# Drop-in desteği kontrolü
# ------------------------------------------------------------

USE_DROPIN=false

if grep -Eq \
'^[[:space:]]*Include[[:space:]]+.*/sshd_config\.d/\*\.conf' \
"$MAIN_CONFIG"; then
    USE_DROPIN=true
fi

# ------------------------------------------------------------
# Config yaz
# ------------------------------------------------------------

echo
echo "SSH ayarları uygulanıyor..."

if [[ "$USE_DROPIN" == true ]]; then

    mkdir -p "$DROPIN_DIR"

    cat > "$DROPIN_FILE" <<'EOF'
# Managed SSH security configuration

PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
EOF

    chmod 600 "$DROPIN_FILE"

    echo "Drop-in oluşturuldu:"
    echo "$DROPIN_FILE"

else

    echo "sshd_config.d Include bulunamadı."
    echo "Ana sshd_config dosyasına managed block ekleniyor."

    # Eski managed block varsa kaldır
    sed -i \
        '/^# BEGIN SSH-SAFE-SETUP$/,/^# END SSH-SAFE-SETUP$/d' \
        "$MAIN_CONFIG"

    cat >> "$MAIN_CONFIG" <<'EOF'

# BEGIN SSH-SAFE-SETUP
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
# END SSH-SAFE-SETUP
EOF

fi

# ------------------------------------------------------------
# Syntax kontrolü
# ------------------------------------------------------------

echo
echo "Yeni SSH config syntax kontrolü..."

if ! sshd -t; then
    echo "ERROR: Yeni SSH configuration geçersiz."
    rollback
    exit 1
fi

echo "OK: Syntax geçerli."

# ------------------------------------------------------------
# Effective config kontrolü
# ------------------------------------------------------------

echo
echo "Effective SSH ayarları:"
echo "------------------------------------------------"

EFFECTIVE_CONFIG="$(sshd -T)"

echo "$EFFECTIVE_CONFIG" | grep -E \
'^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin) '

echo "------------------------------------------------"

PASSWORD_AUTH="$(echo "$EFFECTIVE_CONFIG" | awk '$1=="passwordauthentication"{print $2}')"
KBD_AUTH="$(echo "$EFFECTIVE_CONFIG" | awk '$1=="kbdinteractiveauthentication"{print $2}')"
PUBKEY_AUTH="$(echo "$EFFECTIVE_CONFIG" | awk '$1=="pubkeyauthentication"{print $2}')"
ROOT_LOGIN="$(echo "$EFFECTIVE_CONFIG" | awk '$1=="permitrootlogin"{print $2}')"

if [[ "$PASSWORD_AUTH" != "no" ]]; then
    echo "ERROR: PasswordAuthentication beklenen değer değil."
    rollback
    exit 1
fi

if [[ "$KBD_AUTH" != "no" ]]; then
    echo "ERROR: KbdInteractiveAuthentication beklenen değer değil."
    rollback
    exit 1
fi

if [[ "$PUBKEY_AUTH" != "yes" ]]; then
    echo "ERROR: PubkeyAuthentication beklenen değer değil."
    rollback
    exit 1
fi

if [[ "$ROOT_LOGIN" != "prohibit-password" ]]; then
    echo "ERROR: PermitRootLogin beklenen değer değil."
    rollback
    exit 1
fi

echo
echo "OK: Tüm SSH ayarları doğrulandı."

# ------------------------------------------------------------
# SSH servisini reload et
# ------------------------------------------------------------

echo
echo "SSH servisi reload ediliyor..."

if systemctl list-unit-files ssh.service >/dev/null 2>&1 &&
   systemctl list-unit-files ssh.service | grep -q 'ssh.service'; then

    if ! systemctl reload ssh; then
        echo "ERROR: ssh reload başarısız."
        rollback
        systemctl reload ssh || true
        exit 1
    fi

elif systemctl list-unit-files sshd.service >/dev/null 2>&1 &&
     systemctl list-unit-files sshd.service | grep -q 'sshd.service'; then

    if ! systemctl reload sshd; then
        echo "ERROR: sshd reload başarısız."
        rollback
        systemctl reload sshd || true
        exit 1
    fi

else
    echo "ERROR: ssh veya sshd systemd servisi bulunamadı."
    rollback
    exit 1
fi

# ------------------------------------------------------------
# Sonuç
# ------------------------------------------------------------

echo
echo "============================================================"
echo "SSH AYARLARI BAŞARIYLA UYGULANDI"
echo "============================================================"
echo
echo "PasswordAuthentication       no"
echo "KbdInteractiveAuthentication no"
echo "PubkeyAuthentication         yes"
echo "PermitRootLogin              prohibit-password"
echo
echo "Backup:"
echo "$BACKUP_DIR"
echo
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "MEVCUT SSH OTURUMUNU KAPATMA."
echo
echo "YENİ BİR TERMINAL AÇ VE SSH KEY İLE TEKRAR BAĞLAN."
echo
echo "Yeni bağlantı başarılı olduktan sonra bu oturumu"
echo "kapatabilirsin."
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo
