{
  source = "https://github.com/void-linux/void-mklive.git",
  ref = "master",
  arch = "x86_64",
  variant = "base",
  packages | default = [],
  services | default = [],
  kernel_args | default = [],
  include_dir | default = "modules/include",
  output | default = "void-live-animesh-%{arch}-%{variant}.iso",
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

    kernel_args=(%%{karg_list})

    mklive_args=(
      -p "%%{pkg_list}"
      -S "%%{svc_list}"
      -I "%%{include_dir}"
      -o "%%{output}"
    )

    if [ "${#kernel_args[@]}" -gt 0 ] && [ -n "${kernel_args[0]}" ]; then
      mklive_args+=( -C "${kernel_args[*]}" )
    fi
    "$build_dir/mkiso.sh" "${variant_args[@]}" -- "${mklive_args[@]}"
  "%%,
}
