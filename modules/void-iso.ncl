{
  source = "https://github.com/void-linux/void-mklive.git",
  ref = "master",
  arch = "x86_64",
  variant = "base",
  packages | default = [],
  services | default = [],
  kernel_args | default = [],
  include_dir | default = "modules/include",
  workdir | default = ".build/void-iso",
  isolate = {
    enable | default = false,
    qemu | default = "qemu-system-x86_64",
    ssh_port | default = "2222",
    vm_ram | default = "2048",
    vm_cpus | default = "8",
    seed_iso | default = "https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso",
    user | default = "anon",
    password | default = "voidlinux",
    display | default = "none",
    guest_packages | default = ["ca-certificates", "docker", "dosfstools", "git", "jq", "make", "xz"],
  },
  output | default = "%{workdir}/void-live-%{arch}-%{variant}.iso",
  pkg_list | not_exported = std.string.join " " packages,
  svc_list | not_exported = std.string.join " " services,
  karg_list | not_exported = std.string.join " " kernel_args,
  guest_pkg_list | not_exported = std.string.join " " isolate.guest_packages,
  plan = m%%"
    set -euo pipefail

    on_void=0
    if [ -r /etc/os-release ]; then
      os_id=$(sed -n 's/^ID=//p' /etc/os-release | head -n 1 | tr -d "\"'")
      if [ "$os_id" = "void" ]; then
        on_void=1
      fi
    fi

    if [ "%%{isolate.enable}" != "true" ] || [ "$on_void" = "1" ]; then
      if [ "$(uname -s)" != "Linux" ]; then
        echo >&2 "void-iso requires a Linux host when running inline"
        exit 1
      fi

      if [ "$(id -u)" -ne 0 ]; then
        echo >&2 "void-iso requires root privileges when running inline"
        exit 1
      fi

      build_dir="./%%{workdir}/void-mklive"
      export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
      if [ ! -d "$build_dir/.git" ]; then
        mkdir -p "$(dirname "$build_dir")"
        git clone "%%{source}" "$build_dir"
      fi
      git -C "$build_dir" fetch --depth=1 origin "%%{ref}"
      git -C "$build_dir" checkout --detach "%%{ref}"

      variant_args=(-a "%%{arch}" -b "%%{variant}")

      kernel_args=(%%{karg_list})
      abs_include="$PWD/%%{include_dir}"
      abs_output="$PWD/%%{output}"
      mkdir -p "$(dirname "$abs_output")"

      mklive_args=(
        -p "%%{pkg_list}"
        -S "%%{svc_list}"
        -I "$abs_include"
        -o "$abs_output"
        -K
      )

      if [ "${#kernel_args[@]}" -gt 0 ] && [ -n "${kernel_args[0]}" ]; then
        mklive_args+=( -C "${kernel_args[*]}" )
      fi
      ( cd "$build_dir" && ./mkiso.sh "${variant_args[@]}" -- "${mklive_args[@]}" )
      exit 0
    fi

    qemu=%%{isolate.qemu}
    ssh_port=%%{isolate.ssh_port}
    vm_ram=%%{isolate.vm_ram}
    vm_cpus=%%{isolate.vm_cpus}
    seed_iso=%%{isolate.seed_iso}
    guest_user=%%{isolate.user}
    guest_password=%%{isolate.password}
    output=%%{output}
    started_at=$(date +%s)
    elapsed() { echo "$(( $(date +%s) - started_at ))"; }

    workdir="%%{workdir}"
    mkdir -p "$workdir"
    askpass=$(mktemp "${TMPDIR:-/tmp}/void-iso-askpass.XXXXXX")
    {
      printf '%s\n' '#!/bin/sh'
      printf '%s\n' 'printf '\''%s\n'\'' "%%{isolate.password}"'
    } > "$askpass"
    chmod 0700 "$askpass"
    export SSH_ASKPASS="$askpass"
    export SSH_ASKPASS_REQUIRE=force
    echo "void-iso: guest target %%{isolate.user}@127.0.0.1"
    ssh_opts=(
      -n
      -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null
      -o PreferredAuthentications=password
      -o PubkeyAuthentication=no
    )

    echo "void-iso: preparing seed (elapsed $(elapsed)s)..."
    if [ -z "$seed_iso" ]; then
      echo >&2 "void-iso: isolate.seed_iso is empty; refusing to guess"
      exit 1
    fi

    case "$seed_iso" in
      http://*|https://*)
        seed="$workdir/seed.iso"
        if [ ! -f "$seed" ]; then
          echo "void-iso: downloading seed ISO (elapsed $(elapsed)s)..."
          curl -fL --retry 3 --retry-delay 2 -o "$seed" "$seed_iso"
        fi
        ;;
      *)
        if [ -f "$seed_iso" ]; then
          seed=$(cd "$(dirname "$seed_iso")" && pwd)/$(basename "$seed_iso")
        else
          seed="$seed_iso"
        fi
        ;;
    esac

    ssh_sock="$workdir/qemu-serial.sock"
    rm -f "$ssh_sock"

    echo "void-iso: booting guest (elapsed $(elapsed)s)..."
    case "$(uname -s)/$(uname -m)" in
      Darwin/x86_64) accel="accel=hvf:tcg"; cpu_model="host" ;;
      Linux/x86_64) accel="accel=kvm:tcg"; cpu_model="host" ;;
      *) accel="accel=tcg"; cpu_model="qemu64" ;;
    esac
    qemu_args=(
      "$qemu"
      -name void-iso-build
      -machine "$accel"
      -cpu "$cpu_model"
      -m "$vm_ram" -smp "$vm_cpus"
      -virtfs "local,path=$PWD,mount_tag=recipes,security_model=mapped-xattr,multidevs=remap"
      -drive "file=$seed,media=cdrom,readonly=on"
      -netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22"
      -device virtio-net-pci,netdev=net0
      -serial "unix:$ssh_sock,server=on,wait=off"
      -vga std
      -display "%%{isolate.display}"
      -no-reboot
    )
    "${qemu_args[@]}" &
    qemu_pid=$!

    cleanup() {
      if [ -n "${qemu_pid:-}" ] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
      fi
      rm -f "$ssh_sock" "$askpass"
    }
    trap cleanup EXIT INT TERM

    echo "void-iso: waiting for sshd (elapsed $(elapsed)s)..."
    wait_started=$(date +%s)
    next_progress=15
    until ssh -q "${ssh_opts[@]}" -o ConnectTimeout=2 -p "$ssh_port" \
              "$guest_user@127.0.0.1" true 2>/dev/null; do
      if ! kill -0 "$qemu_pid" 2>/dev/null; then
        echo >&2 "void-iso: QEMU guest exited before sshd came up"
        exit 1
      fi
      wait_elapsed=$(( $(date +%s) - wait_started ))
      if [ "$wait_elapsed" -ge "$next_progress" ]; then
        echo "void-iso: waiting for guest sshd (elapsed ${wait_elapsed}s; guest boot under TCG can take 3-5 minutes)..."
        next_progress=$((next_progress + 15))
      fi
      sleep 1
    done
    echo "void-iso: guest sshd is ready (elapsed $(elapsed)s)"

    echo "void-iso: mounting repository (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      "sudo mkdir -p /mnt/recipes; if ! sudo mountpoint -q /mnt/recipes; then sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 recipes /mnt/recipes; fi; sudo touch /mnt/recipes/$workdir/.write-test && sudo rm -f /mnt/recipes/$workdir/.write-test"

    echo "void-iso: installing guest prerequisites (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      "sudo xbps-install -Syu xbps && sudo xbps-install -Sy %%{guest_pkg_list} && sudo usermod -aG docker $guest_user"

    echo "void-iso: starting docker in guest (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      "sudo ln -sf /etc/sv/docker /var/service/docker && docker_wait_started=\$(date +%s) && while [ ! -S /var/run/docker.sock ]; do if [ \"\$(( \$(date +%s) - docker_wait_started ))\" -ge 60 ]; then echo >&2 'void-iso: docker socket did not appear'; sudo sv status docker >&2 2>&1 || true; exit 1; fi; sleep 1; done"

    echo "void-iso: fetching nickel image (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      'docker pull ghcr.io/tweag/nickel:1.15.1-x86_64 && printf "%s\n" "#!/bin/sh" "exec docker run --rm -i -v \"\$PWD:\$PWD\" -w \"\$PWD\" ghcr.io/tweag/nickel:1.15.1-x86_64 \"\$@\"" | sudo tee /usr/local/bin/nickel >/dev/null && sudo chmod 0755 /usr/local/bin/nickel && nickel --version'

    echo "void-iso: running build (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      "cd /mnt/recipes && sudo make void-iso"

    echo "void-iso: verifying ISO (elapsed $(elapsed)s)..."
    if [ ! -f "$output" ]; then
      echo >&2 "void-iso: no ISO found at $output"
      exit 1
    fi
    output_path="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"
    output_size="$(stat -c %s "$output" 2>/dev/null || stat -f %z "$output")"
    printf 'void-iso: ISO: %s (%s bytes)\n' "$output_path" "$output_size"

    echo "void-iso: shutting down guest (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" "sudo poweroff" >/dev/null 2>&1 || true
    for _ in {1..15}; do
      kill -0 "$qemu_pid" 2>/dev/null || break
      sleep 1
    done
  "%%,
}
