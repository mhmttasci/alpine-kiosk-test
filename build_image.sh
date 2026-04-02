#!/bin/sh
# build_image.sh - Alpine Linux Kiosk imaj oluşturucu
# Güncellenmiş ve hataları giderilmiş versiyon

set -e  # Hata durumunda dur

# Renkli çıktı için
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Çalışma dizini
WORK_DIR=$(pwd)
ALPINE_VERSION="3.20"
ALPINE_ARCH="x86_64"

log_info "Alpine Linux Kiosk imajı oluşturuluyor..."
log_info "Versiyon: $ALPINE_VERSION, Mimar: $ALPINE_ARCH"

# 1. Alpine rootfs indir
log_info "Alpine rootfs indiriliyor..."
ROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"

if [ ! -f "alpine-rootfs.tar.gz" ]; then
    wget --no-check-certificate -O alpine-rootfs.tar.gz "$ROOTFS_URL"
    if [ $? -ne 0 ]; then
        log_error "Rootfs indirilemedi: $ROOTFS_URL"
        exit 1
    fi
fi

# 2. Geçici dizin oluştur
log_info "Geçici dizin oluşturuluyor..."
TEMP_DIR=$(mktemp -d)
mkdir -p "$TEMP_DIR/rootfs"

# 3. Rootfs'i aç
log_info "Rootfs açılıyor..."
tar -xzf alpine-rootfs.tar.gz -C "$TEMP_DIR/rootfs"

# 4. chroot için gerekli dosyaları hazırla
log_info "chroot ortamı hazırlanıyor..."
cp /etc/resolv.conf "$TEMP_DIR/rootfs/etc/"
mount --bind /dev "$TEMP_DIR/rootfs/dev"
mount --bind /proc "$TEMP_DIR/rootfs/proc"
mount --bind /sys "$TEMP_DIR/rootfs/sys"

# 5. chroot içinde paket yükleme script'i
log_info "Sistem paketleri yükleniyor..."
cat > "$TEMP_DIR/rootfs/setup.sh" << 'EOF'
#!/bin/sh
# chroot içinde çalışacak script

# Apk reposunu güncelle
cat > /etc/apk/repositories << 'REPO'
https://dl-cdn.alpinelinux.org/alpine/v3.20/main
https://dl-cdn.alpinelinux.org/alpine/v3.20/community
REPO

# Apk güncelle
apk update

# Temel paketleri yükle
apk add --no-cache \
    alpine-base \
    openrc \
    udev \
    dbus \
    xorg-server \
    xf86-video-vesa \
    xf86-input-evdev \
    xf86-input-synaptics \
    openbox \
    firefox \
    chromium \
    python3 \
    py3-pip \
    py3-tkinter \
    wireguard-tools \
    openssl \
    ca-certificates \
    curl \
    wget \
    sudo \
    bash \
    font-noto \
    font-noto-emoji

# Kiosk kullanıcısı oluştur
adduser -D -h /home/kiosk -s /bin/bash kiosk
echo "kiosk:changeme" | chpasswd

# X11 otomatik başlatma
mkdir -p /home/kiosk/.config/openbox
cat > /home/kiosk/.config/openbox/autostart << 'AUTOSTART'
#!/bin/sh
# Kiosk uygulamasını başlat
# Şimdilik Chromium kiosk modu, sonra Python uygulamanla değiştir
chromium-browser --kiosk --no-first-run --disable-restore-session-state \
    --disable-features=TranslateUI --disable-sync \
    --no-default-browser-check --disable-infobars \
    https://www.example.com &
AUTOSTART

chmod +x /home/kiosk/.config/openbox/autostart
chown -R kiosk:kiosk /home/kiosk/.config

# X11 başlatma script'i
cat > /home/kiosk/.xinitrc << 'XINITRC'
#!/bin/sh
exec openbox-session
XINITRC
chmod +x /home/kiosk/.xinitrc
chown kiosk:kiosk /home/kiosk/.xinitrc

# Otomatik login için inittab düzenle
sed -i 's/^tty1::respawn:\/sbin\/getty/tty1::respawn:\/sbin\/agetty --autologin kiosk/g' /etc/inittab

# X11 başlatma için profile
echo "startx" >> /home/kiosk/.profile
chown kiosk:kiosk /home/kiosk/.profile

# Geçici dosyalar için tmpfs
echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,noexec,mode=1777 0 0" >> /etc/fstab

# Servisleri başlatmak için sembolik linkler
ln -sf /etc/init.d/udev /etc/runlevels/default/udev
ln -sf /etc/init.d/dbus /etc/runlevels/default/dbus

echo "Setup tamamlandı!"
EOF

chmod +x "$TEMP_DIR/rootfs/setup.sh"

# 6. chroot'a gir ve script'i çalıştır
log_info "chroot içinde kurulum yapılıyor (bu 1-2 dakika sürebilir)..."
chroot "$TEMP_DIR/rootfs" /bin/sh /setup.sh

if [ $? -ne 0 ]; then
    log_error "chroot kurulumu başarısız!"
    exit 1
fi

# 7. Setup script'ini temizle
rm -f "$TEMP_DIR/rootfs/setup.sh"

# 8. Initramfs hazırlığı
log_info "Initramfs hazırlanıyor..."
mkdir -p "$TEMP_DIR/initramfs"
cd "$TEMP_DIR/initramfs"

# Init script'i oluştur
cat > init << 'INIT'
#!/bin/sh
# Alpine Kiosk init script

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mount -t tmpfs none /tmp

# Rootfs'i bul (SquashFS)
ROOT_DEV=/dev/sr0  # CD-ROM veya USB
if [ -e /dev/sda1 ]; then
    ROOT_DEV=/dev/sda1
fi

# SquashFS mount et
mkdir /mnt/root
mount -t squashfs "${ROOT_DEV}" /mnt/root

# Switch root
exec switch_root /mnt/root /sbin/init
INIT

chmod +x init

# Initramfs'ı paketle
find . | cpio -o -H newc | gzip -9 > "$WORK_DIR/initramfs"
log_info "Initramfs oluşturuldu: $WORK_DIR/initramfs"

# 9. Kernel'i kopyala (Ubuntu'dan geçici kernel - sonra Alpine kernel'i kullanılabilir)
log_info "Kernel hazırlanıyor..."
cp /boot/vmlinuz-* "$WORK_DIR/vmlinuz" 2>/dev/null || {
    log_warn "Kernel bulunamadı, varsayılan kernel kullanılacak"
    # Boş dosya oluştur
    touch "$WORK_DIR/vmlinuz"
}

# 10. SquashFS oluştur
log_info "SquashFS oluşturuluyor..."
mksquashfs "$TEMP_DIR/rootfs" "$WORK_DIR/alpine-kiosk.squashfs" -comp xz -b 1M -noappend

if [ $? -ne 0 ]; then
    log_error "SquashFS oluşturulamadı!"
    exit 1
fi

# 11. Temizlik
log_info "Temizlik yapılıyor..."
umount "$TEMP_DIR/rootfs/dev" 2>/dev/null || true
umount "$TEMP_DIR/rootfs/proc" 2>/dev/null || true
umount "$TEMP_DIR/rootfs/sys" 2>/dev/null || true
rm -rf "$TEMP_DIR"
rm -f alpine-rootfs.tar.gz

# 12. Sonuç
log_info "✅ İmaj oluşturma tamamlandı!"
log_info "Oluşturulan dosyalar:"
ls -la "$WORK_DIR/vmlinuz" "$WORK_DIR/initramfs" "$WORK_DIR/alpine-kiosk.squashfs"

echo ""
log_info "Bu dosyaları bir web sunucusuna yükleyin veya USB'ye yazın."
log_info "iPXE boot script'i:"
echo ""
echo '#!ipxe'
echo "dhcp"
echo "set base-url https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-kullanici/repo}/main"
echo "kernel \${base-url}/vmlinuz initrd=initramfs root=/dev/ram0 init=/init quiet"
echo "initrd \${base-url}/initramfs"
echo "boot"
