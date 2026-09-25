{
  source = "https://github.com/void-linux/void-mklive.git",
  ref = "master",
  arch = "x86_64",
  variant = "base",
  packages | default = [],
  services | default = [],
  kernel_args | default = [],
  include_dir | default = "modules/include",
  isolate = {
    enable | default = false,
    qemu | default = "qemu-system-x86_64",
    ssh_port | default = "2222",
    vm_ram | default = "2048",
    vm_cpus | default = "2",
    keep_vm | default = true,
    seed_iso | default = "https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso",
    user | default = "anon",
    password | default = "voidlinux",
    use_efi | default = true,
    display | default = "none",
    guest_packages | default = ["git", "jq", "curl", "ca-certificates", "xz", "gptfdisk", "dosfstools", "docker"],
  },
  output | default = "void-live-%{arch}-%{variant}.iso",
  pkg_list | not_exported = std.string.join " " packages,
  svc_list | not_exported = std.string.join " " services,
  karg_list | not_exported = std.string.join " " kernel_args,
  guest_pkg_list | not_exported = std.string.join " " isolate.guest_packages,
  plan = m%%"
    set -euo pipefail

    on_void=0
    if [ -r /etc/os-release ] && grep -q '^ID=void' /etc/os-release; then
      on_void=1
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

      build_dir=./.build/void-mklive
      if [ ! -d "$build_dir/.git" ]; then
        mkdir -p ./.build
        git clone "%%{source}" "$build_dir"
      fi
      git -C "$build_dir" fetch --depth=1 origin "%%{ref}"
      git -C "$build_dir" checkout --detach "%%{ref}"

      variant_args=(-a "%%{arch}" -b "%%{variant}")

      kernel_args=(%%{karg_list})
      abs_include="$PWD/%%{include_dir}"
      abs_output="$PWD/%%{output}"

      mklive_args=(
        -p "%%{pkg_list}"
        -S "%%{svc_list}"
        -I "$abs_include"
        -o "$abs_output"
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
    keep_vm=%%{isolate.keep_vm}
    guest_user=%%{isolate.user}
    guest_password=%%{isolate.password}
    use_efi=%%{isolate.use_efi}
    output=%%{output}
    output_name="$(basename "$output")"
    started_at=$(date +%s)
    elapsed() { echo "$(( $(date +%s) - started_at ))"; }

    build_dir="./.build"
    mkdir -p "$build_dir"
    workspace="/mnt/scratch/workspace"
    askpass="$build_dir/askpass.sh"
    {
      printf '%s\n' '#!/bin/sh'
      printf '%s\n' 'printf '\''%s\n'\'' "%%{isolate.password}"'
    } > "$askpass"
    chmod 0755 "$askpass"
    export SSH_ASKPASS="$askpass"
    export SSH_ASKPASS_REQUIRE=force
    echo "void-iso: guest target %%{isolate.user}@127.0.0.1"
    ssh_opts=(
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
        seed="$build_dir/seed.iso"
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

    echo "void-iso: creating overlay (elapsed $(elapsed)s)..."
    overlay="$build_dir/void-iso-overlay.qcow2"
    overlay_dir="$(dirname "$overlay")"
    rm -f "$overlay"
    qemu-img create -f qcow2 -o preallocation=metadata "$overlay" 20G

    ssh_sock="$overlay_dir/qemu-serial.sock"
    rm -f "$ssh_sock"

    qemu_args=(
      "$qemu"
      -name void-iso-build
    )
    if [ "$use_efi" = "true" ]; then
      efi_code=""
      for candidate in \
        /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE.secboot.fd \
        /usr/share/edk2/x64/OVMF_CODE.fd \
        /usr/share/qemu/OVMF.fd; do
        if [ -f "$candidate" ]; then
          efi_code="$candidate"
          break
        fi
      done

      if [ -n "$efi_code" ]; then
        efi_vars_source=""
        for candidate in \
          /opt/homebrew/share/qemu/edk2-x86_64-vars.fd \
          /usr/share/OVMF/OVMF_VARS.fd \
          /usr/share/edk2/x64/OVMF_VARS.fd; do
          if [ -f "$candidate" ]; then
            efi_vars_source="$candidate"
            break
          fi
        done
        efi_vars="$overlay_dir/edk2-x86_64-vars.fd"
        if [ -n "$efi_vars_source" ]; then
          cp "$efi_vars_source" "$efi_vars"
        else
          dd if=/dev/zero of="$efi_vars" bs=1k count=64
        fi
        qemu_args+=(
          -drive "file=$efi_code,if=pflash,format=raw,readonly=on"
          -drive "file=$efi_vars,if=pflash,format=raw"
        )
      else
        echo >&2 "void-iso: EFI firmware not found; continuing with SeaBIOS"
      fi
    fi

    accel="accel=kvm:tcg"
    cpu_model="host"
    if [ "$(uname -s)" = "Darwin" ]; then
      accel="accel=hvf:tcg"
      cpu_model="qemu64"
    fi

    echo "void-iso: booting guest (elapsed $(elapsed)s)..."
    qemu_args+=(
      -machine "$accel"
      -cpu "$cpu_model"
      -m "$vm_ram" -smp "$vm_cpus"
      -drive "file=$overlay,if=virtio,format=qcow2"
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
      if [ "$keep_vm" != "true" ]; then
        rm -f "$overlay" "$ssh_sock"
      fi
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
        echo "void-iso: waiting for guest sshd (elapsed ${wait_elapsed}s; UEFI+TCG boot can take 3-5 minutes)..."
        next_progress=$((next_progress + 15))
      fi
      sleep 1
    done
    echo "void-iso: guest sshd is ready (elapsed $(elapsed)s)"

    echo "void-iso: preparing scratch disk (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      'if [ ! -b /dev/vda ]; then echo >&2 "void-iso: scratch disk /dev/vda is missing"; exit 1; fi; if [ -z "$(sudo blkid /dev/vda 2>/dev/null)" ]; then sudo mkfs.ext4 -F /dev/vda; fi; sudo mkdir -p /mnt/scratch; if ! sudo mountpoint -q /mnt/scratch; then sudo mount /dev/vda /mnt/scratch; fi; sudo mkdir -p /mnt/scratch/docker /mnt/scratch/workspace; sudo chown %%{isolate.user}:%%{isolate.user} /mnt/scratch/workspace; printf "%s\n" scratch > /mnt/scratch/workspace/.write-test; rm -f /mnt/scratch/workspace/.write-test'

    echo "void-iso: installing guest prerequisites (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      "sudo xbps-install -Syu xbps && sudo xbps-install -Sy %%{guest_pkg_list} && sudo usermod -aG docker $guest_user"

    echo "void-iso: starting docker in guest (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      'sudo mkdir -p /etc/docker && printf "%s\n" "{\"data-root\": \"/mnt/scratch/docker\"}" | sudo tee /etc/docker/daemon.json >/dev/null && sudo ln -sf /etc/sv/docker /var/service/docker && docker_wait_started=$(date +%s) && while [ ! -S /var/run/docker.sock ]; do if [ "$(( $(date +%s) - docker_wait_started ))" -ge 60 ]; then echo >&2 "void-iso: docker socket did not appear"; exit 1; fi; sleep 1; done'

    echo "void-iso: fetching nickel image (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      'docker pull ghcr.io/tweag/nickel:1.15.1-x86_64 && printf "%s\n" "#!/bin/sh" "exec docker run --rm -i -v \"\$PWD:\$PWD\" -w \"\$PWD\" ghcr.io/tweag/nickel:1.15.1-x86_64 \"\$@\"" | sudo tee /usr/local/bin/nickel >/dev/null && sudo chmod 0755 /usr/local/bin/nickel && nickel --version'

    echo "void-iso: copying repo (elapsed $(elapsed)s)..."
    repo_tar="$(pwd)/$build_dir/repo.tar.gz"
    mkdir -p "$(dirname "$repo_tar")"
    tar --exclude=./.build --exclude=./.git -czf "$repo_tar" .

    scp "${ssh_opts[@]}" -P "$ssh_port" \
        "$repo_tar" "$guest_user@127.0.0.1:$workspace/repo.tar.gz"

    build_script="$(pwd)/$build_dir/build.sh"
    tmp_ncl="$build_dir/guest-recipe.ncl"
    printf '%s\n' \
      'let m = import "../modules/void-iso.ncl" in' \
      'let r = import "../recipes/void-iso.ncl" in' \
      'r & { isolate = m.isolate & { enable | force = false } }' > "$tmp_ncl"
    nickel export --format=json "$tmp_ncl" | jq -r .plan > "$build_script"
    chmod 0755 "$build_script"

    scp "${ssh_opts[@]}" -P "$ssh_port" \
        "$build_script" "$guest_user@127.0.0.1:$workspace/build.sh"
    echo "void-iso: running build (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      "cd $workspace && tar -xzf $workspace/repo.tar.gz -C $workspace && cd $workspace && sudo bash build.sh"

    echo "void-iso: retrieving ISO (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      "iso_path=\$(find \"$workspace\" -maxdepth 1 -type f -name 'void-live-*.iso' -print -quit); if [ -z \"\$iso_path\" ]; then echo >&2 \"void-iso: no ISO found in $workspace\"; exit 1; fi; sudo chown $guest_user:$guest_user \"\$iso_path\"; sudo chmod 0644 \"\$iso_path\"; test -r \"\$iso_path\""
    scp "${ssh_opts[@]}" -P "$ssh_port" \
        "$guest_user@127.0.0.1:$workspace/$output_name" "./$output_name"

    echo "void-iso: shutting down guest (elapsed $(elapsed)s)..."
    ssh "${ssh_opts[@]}" -p "$ssh_port" "$guest_user@127.0.0.1" \
      "sudo poweroff" >/dev/null 2>&1 || true
    shutdown_deadline=$(( $(date +%s) + 30 ))
    while kill -0 "$qemu_pid" 2>/dev/null && [ "$(date +%s)" -lt "$shutdown_deadline" ]; do
      sleep 1
    done
    if kill -0 "$qemu_pid" 2>/dev/null; then
      kill "$qemu_pid" 2>/dev/null || true
    fi
    wait "$qemu_pid" 2>/dev/null || true
  "%%,
}
