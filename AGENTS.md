# Repository guidance

## Architecture

- `modules/*.ncl` are reusable records that produce plans; they are not recipes.
- `recipes/*.ncl` expose targets such as `default` and `isolated`, and override module records for each target.
- `lib/void-qemu.ncl` provides the composable `wrap target cfg` wrapper. It returns a shell plan, not a recipe or module.
- Keep module behavior in modules and recipe-specific target choices in recipes.

## Nickel composition

- To override an imported module, use `module | not_exported = base & { ... }`.
- Have targets refer to that same merged module, so their plans include the overrides.
- Do not build a target from a stale imported base plan when overrides must apply.
- `wrap` uses an inline static record type for `cfg`; keep callsites aligned with that type.
- Typecheck and render after changing Nickel composition or types.

## Nickel and shell source

- Use Nickel multiline strings in the `m%%"..."%%` form where shell text needs multiline content.
- Escape interpolation deliberately: distinguish Nickel interpolation from shell variables.
- Use quoted heredoc delimiters when the body must not interpolate; put delimiter lines at column 0.
- Do not add comments to `.ncl` or shell files, except shell shebangs. This `AGENTS.md` may use Markdown prose.
- Run `bash -n` on generated or edited shell scripts/plans where applicable.

## QEMU and 9p

- Use host OVMF firmware paths when configuring QEMU.
- The QEMU wrapper's virtio qcow2 disk uses `discard=unmap` so guest `blkdiscard` can pass through to qcow.
- `keep_disk=true` preserves `.build/<id>/disk.qcow2` for manual QEMU inspection; the `void-server-install` recipe opts in.
- Configure xbps cache through its config/environment, and prepare the guest before testing installs.
- Do not do heavy xbps work or mklive unpacking on a 9p share.
- Use tmpfs for `/build` when the target disk is `/dev/vda`.
- If `void-iso` runs mklive, put `ROOTDIR` on scratch storage rather than 9p when applicable.
- Handle askpass and SSH stdin explicitly; avoid consuming input needed by the invoking command.
- Run target commands through bash when relying on `pipefail`.

## Install and boot details

- For the QEMU `isolated` install target, use a separate merge with the guest disk path; do not alter the normal target's disk setting.
- The install plan destructively clears the ZFS label and discards the selected install disk; this simple reset pattern is intended only for that disk. `blkdiscard -f` disables blkdiscard's exclusive-access guard, is not secure erasure, and may fall back to resetting the GPT with `sgdisk -go`.
- `boot_disk` partition naming varies: `/dev/disk/by-id/*` and `/dev/disk/by-path/*` aliases use `-partN`; mmcblk devices use `pN`; vd/sd devices use plain `N`.
- After importing a root pool with an altroot, set the root boot environment to `canmount=noauto` and its children to `canmount=on`.
- Add only the ESP to fstab; ZFS datasets are managed by the pool.
- Preserve `/var/db/xbps` in the system tar.
- `xchroot` mounts `/dev`, `/proc`, and `/sys`, but not `/run`.
- Install `curl` in the live guest prerequisites before running the install plan; EFI downloads use `curl -fL -o` to write directly to the ESP.

## Testing and artifacts

- First typecheck and render the plan, then syntax-check shell with `bash -n`.
- Smoke-test the smallest subsystem directly through `qemu.wrap` before attempting a full, destructive install.
- Keep all logs under `.build/<recipe>/`; do not write logs to `/tmp`.
- Inspect the latest log and its completion marker. Do not rely on stale rendered files or stale success markers.
- Clean up only generated artifacts whose ownership and paths are known.
- Never claim an end-to-end pass without successful terminal evidence.

## Workflow

- Research uncertainties before changing behavior; keep implementation bounded to the requested fix.
- Run the assigned local tests, then have an independent checker review the result; iterate until green.
- Do not commit or push unless explicitly requested.
