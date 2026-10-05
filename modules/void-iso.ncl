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
  output | default = "%{workdir}/void-live-%{arch}-%{variant}.iso",
  pkg_list | not_exported = std.string.join " " packages,
  svc_list | not_exported = std.string.join " " services,
  karg_list | not_exported = std.string.join " " kernel_args,
  plan = m%%"
    set -euo pipefail

    if [ "$(uname -s)" != "Linux" ]; then
      echo >&2 "void-iso: requires a Linux host"
      exit 1
    fi

    if [ "$(id -u)" -ne 0 ]; then
      echo >&2 "void-iso: requires root privileges"
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
    export XBPS_CACHEDIR="$PWD/%%{workdir}/xbps-cachedir"
    export XBPS_HOST_CACHEDIR="$XBPS_CACHEDIR"

    mklive_args=(
      -p "%%{pkg_list}"
      -S "%%{svc_list}"
      -I "$abs_include"
      -o "$abs_output"
    )

    if [ "${#kernel_args[@]}" -gt 0 ] && [ -n "${kernel_args[0]}" ]; then
      mklive_args+=( -C "${kernel_args[*]}" )
    fi
    export build_dir
    env ROOTDIR=/build bash -c '( cd "$build_dir" && ./mkiso.sh "$@" )' -- "${variant_args[@]}" -- "${mklive_args[@]}"

    if [ ! -s "$abs_output" ]; then
      echo >&2 "void-iso: no ISO produced at $abs_output"
      exit 1
    fi
    iso_size=$(stat -c %s "$abs_output" 2>/dev/null || stat -f %z "$abs_output")
    printf 'void-iso: ISO: %s (%s bytes)\n' "$abs_output" "$iso_size"
  "%%,
}
