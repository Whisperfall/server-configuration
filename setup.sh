#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# SAFE SSH HARDENING
#
# Uygulanan ayarlar:
#   PasswordAuthentication no
#   KbdInteractiveAuthentication no
#   PubkeyAuthentication yes
#   PermitRootLogin prohibit-password
#
# Kullanım:
#   curl -fsSL https://raw.githubusercontent.com/Whisperfall/server-configuration/refs/heads/main/setup-ssh.sh | sudo bash
#
# Belirli kullanıcı:
#   curl ... | sudo TARGET_USER=altan bash
# ============================================================


# ------------------------------------------------------------
# AYARLAR
# ------------------------------------------------------------

MAIN_CONFIG="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN_FILE="$DROPIN_DIR/00-ssh-hardening.conf"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/ssh-config-backup-$TIMESTAMP"


# ------------------------------------------------------------
# ROOT KONTROLÜ
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Script root olarak çalıştırılmalı."
    echo
    echo "Örnek:"
    echo "sudo bash setup-ssh.sh"
    exit 1
fi


# ------------------------------------------------------------
# GEREKLİ KOMUTLAR
# ------------------------------------------------------------

for cmd in sshd systemctl getent id grep awk sed cp chmod chown; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Gerekli komut bulunamadı: $cmd"
        exit 1
    fi
done


# ------------------------------------------------------------
# SSH KULLANICISINI BELİRLE
# ------------------------------------------------------------

if [[ -n "${TARGET_USER:-}" ]]; then
    SSH_USER="$TARGET_USER"

elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    SSH_USER="$SUDO_USER"

else
    SSH_USER="root"
fi


if ! id "$SSH_USER" >/dev/null 2>&1; then
    echo "ERROR: Kullanıcı bulunamadı: $SSH_USER"
    exit 1
fi


USER_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
USER_GROUP="$(id -gn "$SSH_USER")"

if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    echo "ERROR: Home dizini bulunamadı: $SSH_USER"
    exit 1
fi


SSH_DIR="$USER_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"


echo
echo "============================================================"
echo "SSH SAFE SETUP"
echo "============================================================"
echo
echo "SSH kullanıcısı : $SSH_USER"
echo "Home            : $USER_HOME"
echo "authorized_keys : $AUTHORIZED_KEYS"
echo


# ------------------------------------------------------------
# AUTHORIZED_KEYS KONTROLÜ
# ------------------------------------------------------------

if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
    echo "ERROR: authorized_keys bulunamadı."
    echo
    echo "$AUTHORIZED_KEYS"
    echo
    echo "Password authentication KAPATILMADI."
    exit 1
fi


if [[ ! -s "$AUTHORIZED_KEYS" ]]; then
    echo "ERROR: authorized_keys boş."
    echo
    echo "Password authentication KAPATILMADI."
    exit 1
fi


# authorized_keys içinde desteklenen bir public key tipi var mı?
if ! grep -Eq \
'(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+' \
"$AUTHORIZED_KEYS"; then

    echo "ERROR: authorized_keys içinde SSH public key bulunamadı."
    echo
    echo "Password authentication KAPATILMADI."
    exit 1
fi


echo "OK: authorized_keys içinde public key bulundu."


# ------------------------------------------------------------
# SSH DOSYA İZİNLERİ
# ------------------------------------------------------------

chown "$SSH_USER:$USER_GROUP" "$SSH_DIR"
chown "$SSH_USER:$USER_GROUP" "$AUTHORIZED_KEYS"

chmod 700 "$SSH_DIR"
chmod 600 "$AUTHORIZED_KEYS"

echo "OK: SSH dosya izinleri ayarlandı."


# ------------------------------------------------------------
# SSH CONFIG VAR MI?
# ------------------------------------------------------------

if [[ ! -f "$MAIN_CONFIG" ]]; then
    echo "ERROR: $MAIN_CONFIG bulunamadı."
    exit 1
fi


# ------------------------------------------------------------
# MEVCUT CONFIG KONTROLÜ
# ------------------------------------------------------------

echo
echo "Mevcut SSH config kontrol ediliyor..."

if ! sshd -t; then
    echo
    echo "ERROR: Mevcut SSH config zaten hatalı."
    echo "Hiçbir değişiklik yapılmadı."
    exit 1
fi

echo "OK: Mevcut SSH config geçerli."


# ------------------------------------------------------------
# BACKUP
# ------------------------------------------------------------

mkdir -p "$BACKUP_DIR"

cp -a "$MAIN_CONFIG" "$BACKUP_DIR/sshd_config"

if [[ -d "$DROPIN_DIR" ]]; then
    cp -a "$DROPIN_DIR" "$BACKUP_DIR/sshd_config.d"
fi

echo
echo "OK: Backup alındı:"
echo "$BACKUP_DIR"


# ------------------------------------------------------------
# ROLLBACK
# ------------------------------------------------------------

rollback() {

    echo
    echo "============================================================"
    echo "ROLLBACK"
    echo "============================================================"
    echo

    cp -a "$BACKUP_DIR/sshd_config" "$MAIN_CONFIG"

    if [[ -d "$BACKUP_DIR/sshd_config.d" ]]; then

        rm -rf "$DROPIN_DIR"
        cp -a "$BACKUP_DIR/sshd_config.d" "$DROPIN_DIR"

    else

        rm -rf "$DROPIN_DIR"

    fi

    echo "Eski SSH configuration geri yüklendi."
}


# ------------------------------------------------------------
# SSH SERVİSİNİ BUL
# ------------------------------------------------------------

SSH_SERVICE=""

if systemctl cat ssh.service >/dev/null 2>&1; then
    SSH_SERVICE="ssh"

elif systemctl cat sshd.service >/dev/null 2>&1; then
    SSH_SERVICE="sshd"

else
    echo "ERROR: ssh veya sshd systemd servisi bulunamadı."
    exit 1
fi

echo "SSH servisi      : $SSH_SERVICE"


# ------------------------------------------------------------
# DROP-IN DESTEĞİ
# ------------------------------------------------------------

USE_DROPIN=false

if grep -Eq \
'^[[:space:]]*Include[[:space:]]+.*sshd_config\.d/.*\.conf' \
"$MAIN_CONFIG"; then

    USE_DROPIN=true
fi


# ------------------------------------------------------------
# CONFIG UYGULA
# ------------------------------------------------------------

echo
echo "SSH güvenlik ayarları uygulanıyor..."


if [[ "$USE_DROPIN" == true ]]; then

    mkdir -p "$DROPIN_DIR"

    cat > "$DROPIN_FILE" <<'EOF'
# ============================================================
# Managed by setup-ssh.sh
# ============================================================

PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
EOF

    chmod 600 "$DROPIN_FILE"
    chown root:root "$DROPIN_FILE"

    echo "OK: Drop-in oluşturuldu:"
    echo "$DROPIN_FILE"


else

    echo "INFO: sshd_config.d Include bulunamadı."
    echo "Ayarlar ana config dosyasının başına eklenecek."

    TEMP_CONFIG="$(mktemp)"

    cat > "$TEMP_CONFIG" <<'EOF'
# ============================================================
# BEGIN SSH-SAFE-SETUP
# Managed by setup-ssh.sh
# ============================================================

PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password

# ============================================================
# END SSH-SAFE-SETUP
# ============================================================

EOF

    # Daha önce eklenmiş managed block varsa kaldır.
    sed \
        '/^# BEGIN SSH-SAFE-SETUP$/,/^# END SSH-SAFE-SETUP$/d' \
        "$MAIN_CONFIG" >> "$TEMP_CONFIG"

    cat "$TEMP_CONFIG" > "$MAIN_CONFIG"
    rm -f "$TEMP_CONFIG"

fi


# ------------------------------------------------------------
# SYNTAX KONTROLÜ
# ------------------------------------------------------------

echo
echo "Yeni SSH config syntax kontrolü..."

if ! sshd -t; then

    echo
    echo "ERROR: Yeni SSH configuration geçersiz."

    rollback

    exit 1
fi

echo "OK: Syntax geçerli."


# ------------------------------------------------------------
# EFFECTIVE CONFIG
# ------------------------------------------------------------

echo
echo "Effective SSH ayarları:"
echo "------------------------------------------------------------"

EFFECTIVE_CONFIG="$(sshd -T)"

echo "$EFFECTIVE_CONFIG" | grep -E \
'^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin)[[:space:]]'

echo "------------------------------------------------------------"


PASSWORD_AUTH="$(
    echo "$EFFECTIVE_CONFIG" |
    awk '$1=="passwordauthentication" {print $2; exit}'
)"

KBD_AUTH="$(
    echo "$EFFECTIVE_CONFIG" |
    awk '$1=="kbdinteractiveauthentication" {print $2; exit}'
)"

PUBKEY_AUTH="$(
    echo "$EFFECTIVE_CONFIG" |
    awk '$1=="pubkeyauthentication" {print $2; exit}'
)"

ROOT_LOGIN="$(
    echo "$EFFECTIVE_CONFIG" |
    awk '$1=="permitrootlogin" {print $2; exit}'
)"


# ------------------------------------------------------------
# EFFECTIVE CONFIG DOĞRULAMA
# ------------------------------------------------------------

ERROR_FOUND=false


if [[ "$PASSWORD_AUTH" != "no" ]]; then
    echo "ERROR: PasswordAuthentication = [$PASSWORD_AUTH]"
    ERROR_FOUND=true
fi


if [[ "$KBD_AUTH" != "no" ]]; then
    echo "ERROR: KbdInteractiveAuthentication = [$KBD_AUTH]"
    ERROR_FOUND=true
fi


if [[ "$PUBKEY_AUTH" != "yes" ]]; then
    echo "ERROR: PubkeyAuthentication = [$PUBKEY_AUTH]"
    ERROR_FOUND=true
fi


case "$ROOT_LOGIN" in

    prohibit-password|without-password)
        ;;

    *)
        echo "ERROR: PermitRootLogin = [$ROOT_LOGIN]"
        ERROR_FOUND=true
        ;;

esac


if [[ "$ERROR_FOUND" == true ]]; then

    echo
    echo "ERROR: Effective SSH ayarları beklenen durumda değil."

    rollback

    exit 1
fi


echo
echo "OK: Effective SSH ayarları doğrulandı."


# ------------------------------------------------------------
# SERVİS RELOAD
# ------------------------------------------------------------

echo
echo "SSH servisi reload ediliyor..."


if ! systemctl reload "$SSH_SERVICE"; then

    echo
    echo "ERROR: SSH reload başarısız."

    rollback

    echo
    echo "Eski config ile SSH tekrar reload ediliyor..."

    systemctl reload "$SSH_SERVICE" || true

    exit 1
fi


# ------------------------------------------------------------
# RELOAD SONRASI KONTROL
# ------------------------------------------------------------

if ! systemctl is-active --quiet "$SSH_SERVICE"; then

    echo
    echo "ERROR: SSH servisi aktif değil."

    rollback

    systemctl restart "$SSH_SERVICE" || true

    exit 1
fi


if ! sshd -t; then

    echo
    echo "ERROR: Reload sonrası SSH config kontrolü başarısız."

    rollback

    systemctl reload "$SSH_SERVICE" || true

    exit 1
fi


# ------------------------------------------------------------
# SONUÇ
# ------------------------------------------------------------

echo
echo "============================================================"
echo "BAŞARILI"
echo "============================================================"
echo
echo "PasswordAuthentication       : no"
echo "KbdInteractiveAuthentication : no"
echo "PubkeyAuthentication         : yes"
echo "PermitRootLogin              : prohibit-password"
echo
echo "OpenSSH bazı sürümlerde PermitRootLogin değerini"
echo "\"without-password\" olarak gösterebilir."
echo "Bu değer prohibit-password ile eşdeğerdir."
echo
echo "Backup:"
echo "$BACKUP_DIR"
echo
echo "============================================================"
echo "DİKKAT"
echo "============================================================"
echo
echo "MEVCUT SSH OTURUMUNU HENÜZ KAPATMA."
echo
echo "Yeni bir terminal aç ve private key ile tekrar bağlan."
echo
echo "Örnek:"
echo
echo "ssh -i ~/.ssh/id_ed25519 ${SSH_USER}@SERVER_IP"
echo
echo "Yeni bağlantı başarılıysa mevcut oturumu kapatabilirsin."
echo
echo "============================================================"
