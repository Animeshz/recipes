{
  wrap
    : String -> {
        id : String,
        seed : String,
        uefi : Bool,
        qemu : String,
        ram : String,
        cpus : String,
        display : String,
        ssh_port : String,
        user : String,
        password : String,
        share_path : String,
        share_tag : String,
        guest_mount : String,
        disk_size : String,
        packages : String,
        env : String,
      } -> String
    = fun target => fun cfg => m%%"
    set -euo pipefail

    id=%%{cfg.id}
    ssh_port=%%{cfg.ssh_port}
    guest_user=%%{cfg.user}
    workdir=".build/$id"

    started_at=$(date +%s)
    elapsed() { echo "$(( $(date +%s) - started_at ))"; }

    mkdir -p "$workdir"

    seed=%%{cfg.seed}
    case "$seed" in
      "")
        echo >&2 "$id: seed is empty; refusing to guess"
        exit 1
        ;;
      http://*|https://*)
        seed_local="$workdir/seed.iso"
        if [ ! -f "$seed_local" ]; then
          echo "$id: downloading seed ISO (elapsed $(elapsed)s)..."
          curl -fL --retry 3 --retry-delay 2 -o "$seed_local" "$seed"
        fi
        seed="$seed_local"
        ;;
      *)
        if [ -f "$seed" ]; then
          seed=$(cd "$(dirname "$seed")" && pwd)/$(basename "$seed")
        fi
        ;;
    esac

    disk="$workdir/disk.qcow2"
    if [ ! -f "$disk" ]; then
      qemu-img create -f qcow2 "$disk" %%{cfg.disk_size} >/dev/null
    fi

    askpass=$(mktemp "${TMPDIR:-/tmp}/$id-askpass.XXXXXX")
    {
      printf '%s\n' '#!/bin/sh'
      printf '%s\n' 'printf '\''%s\n'\'' "%%{cfg.password}"'
    } > "$askpass"
    chmod 0700 "$askpass"
    export SSH_ASKPASS="$askpass"
    export SSH_ASKPASS_REQUIRE=force

    ssh_opts=(
      -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null
      -o PreferredAuthentications=password
      -o PubkeyAuthentication=no
      -o LogLevel=ERROR
    )

    case "$(uname -s)/$(uname -m)" in
      Darwin/x86_64) accel="accel=hvf:tcg"; cpu_model="host" ;;
      Linux/x86_64) accel="accel=kvm:tcg"; cpu_model="host" ;;
      *) accel="accel=tcg"; cpu_model="qemu64" ;;
    esac

    echo "$id: booting guest (elapsed $(elapsed)s)..."
    qemu_args=(
      "%%{cfg.qemu}"
      -name "$id"
      -machine "$accel"
      -cpu "$cpu_model"
      -m "%%{cfg.ram}" -smp "%%{cfg.cpus}"
      -virtfs "local,path=%%{cfg.share_path},mount_tag=%%{cfg.share_tag},security_model=mapped-xattr,multidevs=remap"
%%{if cfg.uefi then m%"
      -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.fd
      -drive if=pflash,format=raw,file=/usr/share/edk2/x64/OVMF_VARS.fd
"% else ""}
      -drive "file=$seed,media=cdrom,readonly=on"
      -drive "file=$disk,if=virtio,format=qcow2"
      -netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22"
      -device virtio-net-pci,netdev=net0
      -serial "unix:$workdir/qemu-serial.sock,server=on,wait=off"
      -vga std
      -display "%%{cfg.display}"
      -no-reboot
    )
    "${qemu_args[@]}" &
    qemu_pid=$!

    cleanup() {
      if [ -n "${qemu_pid:-}" ] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
      fi
      rm -f "$workdir/qemu-serial.sock" "$askpass" "$disk"
    }
    trap cleanup EXIT INT TERM

    echo "$id: waiting for sshd (elapsed $(elapsed)s)..."
    wait_started=$(date +%s)
    next_progress=15
    until ssh -q "${ssh_opts[@]}" -o ConnectTimeout=2 -p "$ssh_port" "$guest_user@127.0.0.1" true </dev/null 2>/dev/null; do
      if ! kill -0 "$qemu_pid" 2>/dev/null; then
        echo >&2 "$id: QEMU guest exited before sshd came up"
        exit 1
      fi
      wait_elapsed=$(( $(date +%s) - wait_started ))
      if [ "$wait_elapsed" -ge "$next_progress" ]; then
        echo "$id: waiting for guest sshd (elapsed ${wait_elapsed}s; TCG boots can take 3-5 minutes)..."
        next_progress=$((next_progress + 15))
      fi
      sleep 1
    done
    echo "$id: guest sshd is ready (elapsed $(elapsed)s)"

    echo "$id: preparing guest (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" sh -s <<'__GUEST_PREP__'
      set -e
      sudo mkdir -p %%{cfg.guest_mount}
      if ! sudo mountpoint -q %%{cfg.guest_mount}; then
        sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 %%{cfg.share_tag} %%{cfg.guest_mount}
      fi
      if [ -z "$(sudo blkid /dev/vda 2>/dev/null)" ]; then
        sudo mkfs.ext4 -F /dev/vda
      fi
      sudo mkdir -p /build
      if ! sudo mountpoint -q /build; then
        sudo mount /dev/vda /build
      fi
      sudo touch /build/.write-test && sudo rm -f /build/.write-test
      sudo mkdir -p /etc/xbps.d
      printf 'cachedir=%%{cfg.guest_mount}/.build/%%{cfg.id}/xbps-cachedir\n' | sudo tee /etc/xbps.d/10-cache.conf >/dev/null
      export XBPS_CACHEDIR="%%{cfg.guest_mount}/.build/%%{cfg.id}/xbps-cachedir"
      export XBPS_HOST_CACHEDIR="$XBPS_CACHEDIR"
      sudo xbps-install -Syu xbps %%{if cfg.uefi then "edk2-ovmf " else ""}%%{cfg.packages}
      echo "%%{cfg.id}: guest prepared"
__GUEST_PREP__

    echo "$id: running target (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" "sudo %%{cfg.env} bash -s" <<'__GUEST_TARGET__'
set -e
cd %%{cfg.guest_mount}
%%{target}
__GUEST_TARGET__

    echo "$id: shutting down guest (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" "sudo poweroff" </dev/null >/dev/null 2>&1 || true
    for _ in {1..15}; do
      kill -0 "$qemu_pid" 2>/dev/null || break
      sleep 1
    done
  "%%,
}
