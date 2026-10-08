{
  pool = "boot-pool",
  boot_disk | default = "",
  server_name = "void-server",
  keymap = "us",
  timezone = "Asia/Kolkata",
  primary_user = "animesh",
  primary_user_passwd_hash | default = "",
  release = "https://repo-default.voidlinux.org/current",
  packages = ["zfs", "openssh", "chrony", "dhcpcd", "docker", "curl", "ca-certificates", "git", "bash", "xz", "gptfdisk", "dosfstools", "efibootmgr", "sudo"],
  services = ["sshd", "chronyd", "dhcpcd", "docker", "code-server"],
  code_server_version = "4.138.0",
  plan = m%%"
    set -euo pipefail
    PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
    export PATH
    if [ "$(uname -s)" != "Linux" ]; then
      echo >&2 "void-server-install requires a Linux host"
      exit 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
      echo >&2 "void-server-install requires root privileges"
      exit 1
    fi
    if [ ! -b "%%{boot_disk}" ]; then
      echo >&2 "install disk %%{boot_disk} not found"
      exit 1
    fi
    part_dev() {
      case "$1" in
        /dev/disk/by-id/*|/dev/disk/by-path/*) printf '%s-part%s\n' "$1" "$2" ;;
        *[0-9]) printf '%sp%s\n' "$1" "$2" ;;
        *) printf '%s%s\n' "$1" "$2" ;;
      esac
    }
    disk_path="%%{boot_disk}"
    esp_path=$(part_dev "$disk_path" 1)
    pool_path=$(part_dev "$disk_path" 2)
    zpool labelclear -f "$disk_path" || true
    blkdiscard -f "$disk_path" || sgdisk -go "$disk_path"
    zgenhostid -f abadf00d
    sgdisk --new=1:1M:+550M --typecode=1:ef00 "$disk_path"
    sgdisk --new=2:0:-10M --typecode=2:bf00 "$disk_path"
    partprobe "$disk_path"
    udevadm settle
    if ! command -v zfs >/dev/null 2>&1 || ! command -v zpool >/dev/null 2>&1; then
      echo >&2 "void-server-install: zfs/zpool userland tools not found on PATH"
      exit 1
    fi
    zpool create -f \
      -o ashift=12 \
      -O compression=zstd \
      -O acltype=posixacl \
      -O xattr=sa \
      -O relatime=on \
      -o autotrim=on \
      -m none \
      %%{pool} "$pool_path"
    zfs create -o mountpoint=none %%{pool}/ROOT
    zfs create -o mountpoint=/ -o canmount=noauto %%{pool}/ROOT/%%{server_name}
    for path in audit conf data etc home mnt opt root usr var; do
      zfs create -o canmount=noauto -o mountpoint="/$path" %%{pool}/ROOT/%%{server_name}/$path
    done
    zpool set bootfs=%%{pool}/ROOT/%%{server_name} %%{pool}
    zfs set org.zfsbootmenu:commandline="quiet loglevel=4" %%{pool}/ROOT
    zpool export %%{pool}
    zpool import -N -R /mnt %%{pool}
    for path in audit conf data etc home mnt opt root usr var; do
      zfs set canmount=on %%{pool}/ROOT/%%{server_name}/$path
    done
    zfs mount %%{pool}/ROOT/%%{server_name}
    zfs mount -a
    mkdir -p /mnt/boot/efi
    mkfs.vfat -F32 "$esp_path"
    esp_uuid=$(blkid -s UUID -o value "$esp_path")
    printf 'UUID=%s\t/boot/efi\tvfat\tdefaults,noatime\t0\t2\n' "$esp_uuid" > /mnt/etc/fstab
    mount "$esp_path" /mnt/boot/efi
    tar --create --one-file-system --xattrs --exclude=/sys -f - / |
      tar --extract --xattrs --xattrs-include='*' --preserve-permissions --numeric-owner -f - -C /mnt
    mkdir -p /mnt/proc /mnt/sys /mnt/dev /mnt/run /mnt/tmp
    mkdir -p /mnt/dev/pts /mnt/dev/shm
    chmod 1777 /mnt/tmp
    cp /etc/hostid /mnt/etc/
    cat > /mnt/etc/dracut.conf.d/zol.conf <<'EOF'
    nofsck="yes"
    add_dracutmodules+=" zfs "
    omit_dracutmodules+=" btrfs resume "
    EOF
    echo %%{server_name} > /mnt/etc/hostname
    cat > /mnt/etc/rc.conf <<EOF
    KEYMAP=%%{keymap}
    HARDWARECLOCK=UTC
    TIMEZONE=%%{timezone}
    EOF
    ln -sf /usr/share/zoneinfo/%%{timezone} /mnt/etc/localtime
    if [ -f /mnt/etc/default/libc-locales ]; then
      sed -i.bak -E 's/^#(en_US.UTF-8.*)/\1/' /mnt/etc/default/libc-locales
    fi
    mkdir -p /mnt/boot/efi/EFI/ZBM
    curl -fL --retry 3 --retry-delay 2 \
      -o /mnt/boot/efi/EFI/ZBM/VMLINUZ.EFI \
      https://get.zfsbootmenu.org/efi
    test -s /mnt/boot/efi/EFI/ZBM/VMLINUZ.EFI
    cp /mnt/boot/efi/EFI/ZBM/VMLINUZ.EFI /mnt/boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
    mkdir -p /mnt/boot/efi/EFI/BOOT
    cp /mnt/boot/efi/EFI/ZBM/VMLINUZ.EFI /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI
    xchroot /mnt /bin/bash <<'CHROOT'
    set -euo pipefail
    mount -t tmpfs tmpfs /run -o mode=0755,nosuid,nodev

    xbps-reconfigure -fa
    chown root:root /
    chmod 755 /
    install -d -m 0750 /etc/sudoers.d
    printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/00-wheel
    chmod 0440 /etc/sudoers.d/00-wheel
    for svc in %%{std.string.join " " services}; do
      ln -sf /etc/sv/"$svc" /etc/runit/runsvdir/default/
    done
    useradd -m -G wheel,docker -s /bin/bash %%{primary_user}
    if [ -n '%%{primary_user_passwd_hash}' ]; then
      printf '%s:%s\n' '%%{primary_user}' '%%{primary_user_passwd_hash}' | chpasswd -e
    else
      passwd -d %%{primary_user}
    fi
    install -d -o %%{primary_user} -g %%{primary_user} \
      /home/%%{primary_user}/.share \
      /home/%%{primary_user}/.local/bin \
      /home/%%{primary_user}/.local/lib \
      /home/%%{primary_user}/.config
    xbps-install -Syu nodejs curl
    curl -fL "https://github.com/coder/code-server/releases/download/v%%{code_server_version}/code-server-%%{code_server_version}-linux-amd64.tar.gz" \
      | tar -C /home/%%{primary_user}/.share -xz
    mv /home/%%{primary_user}/.share/code-server-%%{code_server_version}-linux-amd64 /home/%%{primary_user}/.share/code-server
    ln -sf /home/%%{primary_user}/.share/code-server/bin/code-server \
      /home/%%{primary_user}/.local/bin/code-server
    chown -R %%{primary_user}:%%{primary_user} /home/%%{primary_user}
    install -d /etc/sv/code-server
    cat > /etc/sv/code-server/run <<EOF2
    #!/bin/sh
    exec chpst -u %%{primary_user} env HOME=/home/%%{primary_user} /home/%%{primary_user}/.share/code-server/bin/code-server \\
      --bind-addr 0.0.0.0:8080 --auth none --disable-telemetry
    EOF2
    chmod 0755 /etc/sv/code-server/run
    ln -sf /etc/sv/code-server /etc/runit/runsvdir/default/code-server

    CHROOT
    zfs snapshot %%{pool}/ROOT/%%{server_name}@post-install
    umount -n -R /mnt
    zpool export %%{pool}
    echo "void-server-install completed; reboot to enter %%{pool}/ROOT/%%{server_name}."
    sync
  "%%,
}
