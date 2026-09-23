{
  source = "https://github.com/void-linux/void-mklive.git",
  ref = "3aa194bdea9c83de0b5d78fb889a88f000a44fab",
  arch = "x86_64",
  variant = "base",
  packages = [],
  services = ["sshd", "chronyd", "dhcpcd", "wpa_supplicant", "acpid"],
  kernel_args = [],
  output | default = "void-live-x86_64-base.iso",
  pkg_list | not_exported = std.string.join " " packages,
  svc_list | not_exported = std.string.join " " services,
  karg_list | not_exported = std.string.join " " kernel_args,
  plan = m%%"
    set -euo pipefail

    if [ "$(uname -s)" != "Linux" ]; then
      echo >&2 "void-iso requires a Linux host"
      exit 1
    fi

    if [ "$(id -u)" -ne 0 ]; then
      echo >&2 "void-iso requires root privileges"
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
    mklive_args=(-p "%%{pkg_list}" -S "%%{svc_list}" -C "%%{karg_list}" -o "%%{output}")
    "$build_dir/mkiso.sh" "${variant_args[@]}" -- "${mklive_args[@]}"
  "%%,
}
