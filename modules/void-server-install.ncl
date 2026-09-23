{
  source = "https://github.com/void-linux/void-mklive.git",
  ref = "3aa194bdea9c83de0b5d78fb889a88f000a44fab",
  repo = "https://github.com/Animeshz/recipes.git",
  repo_ref = "main",
  pool = "boot-pool",
  data_pool = "ZFS",
  data_mountpoint = "/mnt/ZFS",
  esp_partlabel = "boot-esp",
  micro_sd_disk | default = "",
  micro_sd_part = "2",
  micro_sd_esp = "1",
  be | default = "void",
  hostname = "void-server",
  keymap = "us",
  timezone = "UTC",
  root_user = "animesh",
  release = "https://repo-default.voidlinux.org/current",
  packages = ["zfs", "openssh", "chrony", "dhcpcd", "docker", "curl", "ca-certificates", "git", "bash", "xz", "gptfdisk", "dosfstools", "efibootmgr", "sudo"],
  services = ["sshd", "chronyd", "dhcpcd", "docker", "code-server"],
  code_server_version = "4.138.0",
  plan = m%%"
    set -euo pipefail

    if [ "$(uname -s)" != "Linux" ]; then
      echo >&2 "void-server-install requires a Linux host"
      exit 1
    fi

    if [ "$(id -u)" -ne 0 ]; then
      echo >&2 "void-server-install requires root privileges"
      exit 1
    fi

    if [ ! -b "%%{micro_sd_disk}" ]; then
      echo >&2 "micro SD disk %%{micro_sd_disk} not found"
      exit 1
    fi

    disk_path="%%{micro_sd_disk}"
    esp_path="${disk_path}-part%%{micro_sd_esp}"
    pool_path="${disk_path}-part%%{micro_sd_part}"

    zpool_labelclear -f "$disk_path" || true
    sgdisk --zap-all "$disk_path"
    sgdisk -n "%%{micro_sd_esp}:1m:+512m" -t "%%{micro_sd_esp}:ef00" "$disk_path"
    sgdisk -n "%%{micro_sd_part}:0:-10m" -t "%%{micro_sd_part}:bf00" "$disk_path"
    partprobe "$disk_path"
    udevadm settle

    zgenhostid

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
    zfs create -o mountpoint=/ -o canmount=noauto %%{pool}/ROOT/%%{be}

    for path in audit conf data etc home mnt opt root usr var; do
      zfs create -o mountpoint="/$path" %%{pool}/ROOT/%%{be}/$path
    done

    zpool set bootfs=%%{pool}/ROOT/%%{be} %%{pool}
    zfs set org.zfsbootmenu:commandline="quiet loglevel=4" %%{pool}/ROOT

    zpool export %%{pool}
    zpool import -N -R /mnt %%{pool}
    zfs mount %%{pool}/ROOT/%%{be}
    zfs mount -a

    mkdir -p /mnt/etc/zfs
    zpool set cachefile=/mnt/etc/zfs/zpool.cache %%{pool}

    mkdir -p /mnt/boot/efi
    mkfs.vfat -F32 "$esp_path"
    mount "$esp_path" /mnt/boot/efi

    mkdir -p /mnt/var/db/xbps/keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
    cp /etc/hostid /mnt/etc/

    XBPS_ARCH=x86_64 xbps-install \
      -S \
      -R %%{release} \
      -r /mnt \
      base-system \
      %%{std.string.join " " packages}

    xbps-install -S -r /mnt zfs
    xbps-install -S -r /mnt efibootmgr

    cat > /mnt/etc/dracut.conf.d/zol.conf <<'EOF'
    nofsck="yes"
    add_dracutmodules+=" zfs "
    omit_dracutmodules+=" btrfs resume "
    EOF

    echo %%{hostname} > /mnt/etc/hostname
    cat > /mnt/etc/rc.conf <<EOF
    KEYMAP=%%{keymap}
    HARDWARECLOCK=UTC
    TIMEZONE=%%{timezone}
    EOF
    ln -sf /usr/share/zoneinfo/%%{timezone} /mnt/etc/localtime

    if [ -f /mnt/etc/default/libc-locales ]; then
      sed -e "s/\\#\\(en_US.UTF-8.*\\)/\\1/" -i /mnt/etc/default/libc-locales
    fi

    mkdir -p /mnt/boot/efi/EFI/ZBM
    xbps-uhelper fetch "https://get.zfsbootmenu.org/efi" >/mnt/boot/efi/EFI/ZBM/VMLINUZ.EFI
    xbps-uhelper fetch "https://get.zfsbootmenu.org/efi" >/mnt/boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
    cp /mnt/boot/efi/EFI/ZBM/VMLINUZ.EFI /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI

    xchroot /mnt /bin/bash <<'CHROOT'
    set -euo pipefail

    xbps-reconfigure -fa

    for svc in %%{std.string.join " " services}; do
      ln -sf /etc/sv/"$svc" /etc/runit/runsvdir/default/
    done

    usermod -aG wheel,docker %%{root_user}

    useradd -m -G wheel,docker -s /bin/bash %%{root_user} || true
    passwd %%{root_user}

    if [ ! -d /home/%%{root_user}/.local ]; then
      mkdir -p /home/%%{root_user}/.local/bin /home/%%{root_user}/.local/lib /home/%%{root_user}/.config
    fi

    xbps-install -S nodejs npm || true
    curl -fL "https://github.com/coder/code-server/releases/download/v%%{code_server_version}/code-server-%%{code_server_version}-linux-amd64.tar.gz" \
      | tar -C /home/%%{root_user}/.local/lib -xz
    mv /home/%%{root_user}/.local/lib/code-server-%%{code_server_version} /home/%%{root_user}/.local/lib/code-server
    ln -sf /home/%%{root_user}/.local/lib/code-server/bin/code-server \
      /home/%%{root_user}/.local/bin/code-server

    chown -R %%{root_user}:%%{root_user} /home/%%{root_user}

    install -d /etc/sv/code-server
    cat > /etc/sv/code-server/run <<EOF2
    #!/bin/sh
    exec chpst -u %%{root_user} %%{data_mountpoint}/code-server/code-server \\
      --config %%{data_mountpoint}/code-server/config.yaml \\
      --bind-addr 127.0.0.1:8080 \\
      --user-data-dir %%{data_mountpoint}/code-server/data \\
      --extensions-dir %%{data_mountpoint}/code-server/extensions
    EOF2
    chmod 0755 /etc/sv/code-server/run
    ln -sf /etc/sv/code-server /etc/runit/runsvdir/default/code-server

    mkdir -p /etc/zfs
    zpool set cachefile=/etc/zfs/zpool-cache %%{pool}

    xbps-reconfigure -fa
    CHROOT

    zfs snapshot %%{pool}/ROOT/%%{be}@post-install

    umount -n -R /mnt
    zpool export %%{pool}
    zpool export %%{data_pool} || true

    echo "void-server-install completed; reboot to enter %%{pool}/ROOT/%%{be}."
    sync
  "%%,
}
