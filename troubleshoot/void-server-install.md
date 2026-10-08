# void-server-install — Troubleshooting Log

Problems encountered while developing the `void-server-install` recipe and its
`isolated` QEMU work on a macOS host. All run logs are kept under
`.build/void-server-install/`.

**Architecture in one glance**

```
host                         QEMU, host-side OVMF, and the seed ISO
guest live system            package preparation and the install shell
9p share                     recipe checkout, caches, and build metadata
isolated virtio disk         install target, exposed as /dev/vda
tmpfs /build                 wrapper scratch space; no longer the target disk
```

**Positive milestones**

- The ISO prerequisite passed.
- QEMU boots UEFI with host OVMF detection.
- Guest package preparation completes.
- The ZFS pool and all datasets through `var` complete after setting child
  datasets to `canmount=noauto`.
- Tar extraction follows the upstream Void `copy_rootfs` pattern. It uses
  `--one-file-system` to avoid traversing separately mounted source subtrees,
  including the target ZFS hierarchy under `/mnt`. The local pipeline excludes
  only `/sys`, whose volatile metadata triggered a tar producer error with
  strict `pipefail`; `/var/db/xbps` is preserved naturally.
- ESP setup and both ZFSBootMenu EFI downloads complete; the fallback image is
  placed at `EFI/BOOT/BOOTX64.EFI`.
- Only the ESP is listed in fstab. No ZFS cachefile setter is used; ZFSBootMenu
  discovers/imports the pool, and exporting the pool removes it from the cache
  file.

The latest fresh-qcow run failed during tar with `tar: /sys: file changed as we
read it`. The `/sys` exclusion addresses that volatile metadata change; this
does not establish that a rerun has passed.

The code-server binary installs at
`/home/<primary_user>/.share/code-server` and runs with that home as `HOME`.
Config, user data, and extensions remain at code-server's default locations
under `HOME`; no custom path flags are supplied.

The current installer uses `primary_user` (default `animesh`), `boot_disk`,
and one `server_name` (default `void-server`) for both `/etc/hostname` and
the root boot-environment path. The normal disk is
`/dev/disk/by-id/microsd-1`; isolated QEMU uses `/dev/vda`. Partition 1 is
the ESP and partition 2 is the ZFS pool. No data pool or mountpoint is
configured; code-server's default config is
`$HOME/.config/code-server/config.yaml`.

`primary_user_passwd_hash` configures the primary user's password. A nonempty
hash is applied with `chpasswd -e`; an empty value runs `passwd -d`, leaving
the account passwordless so the user can set a password manually later.

The isolated `void-server-install` recipe keeps its qcow2 install disk after a
future run so it can be inspected or booted manually. The current
`.build/void-server-install/disk.qcow2` currently exists and is available for
inspection or manual boot. Boot it on macOS with:

```sh
qemu-system-x86_64 \
  -machine accel=tcg \
  -cpu qemu64 \
  -m 8G -smp 8 \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -drive if=pflash,format=raw,file=.build/void-server-install/OVMF_VARS.fd \
  -drive file=.build/void-server-install/disk.qcow2,if=virtio,format=qcow2 \
  -display cocoa
```

**Summary**

| # | Problem | Root cause | Fix / current status |
|---|---|---|---|
| 1 | Missing `.default` / `.isolated` targets | The old thin recipe had no target fields | Added module, default, and isolated recipe structure |
| 2 | OVMF host path missing | Void's firmware path was unavailable on macOS | Detect host-side OVMF candidates and fall back for VARS |
| 3 | ISO extraction dead end | The live ISO has boot files and `LiveOS/squashfs.img`, not OVMF firmware | Reverted the extraction approach |
| 4 | Physical install disk absent in the guest | QEMU does not provide `/dev/disk/by-id/microsd-1` | `boot_disk` is `/dev/disk/by-id/microsd-1` for the normal recipe and `/dev/vda` for isolated |
| 5 | `partprobe` missing | Wrapper guest packages did not include `parted` | Added `parted` to isolated guest packages |
| 6 | Invalid `/dev/vda-part2` path | Partition naming differed between device forms | Restored `part_dev()` to produce `/dev/vda2` and preserve by-id forms |
| 7 | Disk reset logic was unnecessarily complex | The isolated install uses a qcow2 disk | Clear the ZFS label on the selected install disk, discard it, and reset the GPT if discard fails; this is destructive and intended only for that disk |
| 8 | `/dev/vda` busy | The wrapper mounted the whole install disk at `/build` | Use tmpfs at `/build` and leave `/dev/vda` to the install plan |
| 9 | `/sbin/zfs` disappeared | A ZFS child dataset mounted over the live installer's `/usr` | Set children `canmount=noauto` until importing under `/mnt`; invoke bare `zfs`/`zpool` commands through the explicit `PATH` and verify them with `command -v` |
| 10 | ZFS child mounts hid live `/usr` and would not mount at boot | Child datasets need to avoid automatic live-root mounts during creation, but `canmount=noauto` persists and excludes them from boot-time `zfs mount -a` | Create children as `canmount=noauto`, import under `/mnt`, then set children to `canmount=on` before mounting them beneath the altroot |
| 11 | Tar stream corruption | Producer diagnostics were mixed into the archive by `2>&1 \|` | Remove the redirect, follow upstream Void's `copy_rootfs` tar pattern, and preserve ownership with `--numeric-owner` |
| 12 | EFI fallback directory missing | `EFI/BOOT` did not exist before copying `BOOTX64.EFI` | Create the directory first; the fallback EFI image is installed on the ESP, the only filesystem in fstab |
| 13 | Chroot `xbps-reconfigure -fa` failed | A prior tar copy excluded `/var/db/xbps`, removing per-package plist metadata needed by reconfiguration | Preserve `/var/db/xbps` naturally with upstream Void's tar pattern; retain one all-package reconfigure after locale setup |
| 16 | Isolated retry uses a retained disk | A preserved qcow2 can contain stale GPT/ZFS state | The installer clears the ZFS label and discards the selected install disk; remove `.build/void-server-install/disk.qcow2` for a fresh-qcow retry if needed |
| 17 | `/etc/hostid` already existed in the live installer | The live ISO provides `/etc/hostid`, causing plain `zgenhostid` to exit with EEXIST | Run `zgenhostid -f abadf00d` before pool creation, then copy that hostid into `/mnt/etc/`; hostids should be unique per machine |
| 18 | Tar reported `/sys` changed during archive creation | GNU tar may stat a changing mountpoint directory and report a metadata change even when `--one-file-system` skips traversal; strict `pipefail` surfaced the producer status | Exclude only `/sys` from the tar producer; retain `set -euo pipefail` and leave extraction unchanged. The fix has not been rerun |
| 19 | ZFSBootMenu EFI files contained progress text and an `efi` artifact appeared in the repository root (resolved) | Historically, `xbps-uhelper fetch URL` wrote its download to the current working directory using the URL basename, while progress went to stdout; redirecting stdout corrupted both ESP files and left the downloaded `efi` file in the 9p checkout | Install `curl` in the live guest prerequisites before running the install plan. The installer now downloads directly to `EFI/ZBM/VMLINUZ.EFI` with `curl -fL -o`, checks for a nonempty file, then copies the backup and EFI/BOOT fallback |

---

## 1. Missing `.default` and `.isolated` targets

**Problem.** The thin `void-server-install` recipe did not expose the targets
needed by the recipe runner, so `.default` and `.isolated` could not be built.

**Root cause.** The original recipe contained configuration and a plan, but no
separate module/default/isolated target structure.

**Fix.** Split the recipe into a reusable module, a normal `default` target,
and an `isolated` target. The isolated target wraps `module_isolated.plan` in
QEMU while the default target uses the module plan directly.

---

## 2. OVMF host path missing

**Problem.** UEFI startup failed because the expected OVMF path was not
available on the macOS host.

**Root cause.** The Void guest's firmware package path cannot be assumed to be
a host path, and Homebrew/macOS may install only a different OVMF code file.

**Fix.** The QEMU wrapper searches host-side OVMF code candidates, uses a
sibling `OVMF_VARS.fd` when present, and creates a fallback VARS file when it
is not. Host OVMF detection now allows the guest to boot UEFI.

---

## 3. ISO extraction was a dead end

**Problem.** Extracting firmware from the Void live ISO did not produce an
OVMF image for QEMU.

**Root cause.** The live ISO contains boot files and
`LiveOS/squashfs.img`; it does not contain OVMF firmware. OVMF is host firmware,
not a file to extract from this seed ISO.

**Fix.** Reverted the extraction approach. UEFI firmware is now detected on the
host, independently of the seed ISO.

---

## 4. The physical microSD path was absent in the guest

**Problem.** The install plan could not find `/dev/disk/by-id/microsd-1` when
running in QEMU.

**Root cause.** That by-id path describes the physical host installation
device. The isolated wrapper presents its qcow2 disk as a virtio block device,
not as the host's physical microSD device.

**Fix.** Keep the physical path in the normal module target, but configure
`module_isolated` with `/dev/vda` so the isolated recipe operates on the QEMU
install disk.

---

## 5. `partprobe` was missing

**Problem.** Partition-table creation stopped at the `partprobe` step.

**Root cause.** The wrapper's guest package list did not include `parted`, which
provides `partprobe`.

**Fix.** Added `parted` to the isolated guest packages. Package preparation now
completes and the partition-table refresh can run.

---

## 6. Partition naming mismatch

**Problem.** The plan constructed `/dev/vda-part2`, which is not a valid
partition path for the QEMU virtio disk.

**Root cause.** The partition suffix convention was applied uniformly even
though `/dev/vda` uses `/dev/vda2`, while by-id device forms have their own
partition naming conventions.

**Fix.** Restored `part_dev()` so the virtio path produces `/dev/vda2` while
preserving the appropriate by-id partition forms.

---

## 7. Wrong `zpool_labelclear` spelling

**Problem.** A cleanup or disk-reset step reported that `zpool_labelclear`
could not be found.

**Root cause.** `labelclear` is a `zpool` subcommand, not a binary named
`zpool_labelclear`.

**Fix.** Invoke the command as `zpool labelclear`.

---

## 8. `/dev/vda` was busy

**Problem.** Pool creation could not take ownership of `/dev/vda` because the
device was already in use.

**Root cause.** The QEMU wrapper mounted the entire install disk at `/build`
for scratch space. The install plan then attempted to partition and use that
same disk.

**Fix.** `/build` is now a guest tmpfs. The attached virtio disk remains free
for the install plan, which owns `/dev/vda` from partitioning through ZFS
creation.

---

## 9. `/sbin/zfs` disappeared during the dataset loop

**Problem.** The observed failure during the ZFS dataset loop reported that
`/sbin/zfs` was no longer available.

**Root cause.** The `usr` child dataset mounted over the live installer's
`/usr`, hiding the ZFS binaries used by the install shell.

**Fix.** Create child datasets as `canmount=noauto`, then enable and mount them
only after importing the pool under `/mnt`. The shell sets
`PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH`, checks both tools with
`command -v`, and invokes bare `zfs` and `zpool` commands. With the live `/usr`
no longer shadowed, those commands resolve through `PATH` for the complete
install sequence.

---

## 10. ZFS dataset shadowing

**Problem.** The pool and datasets could be created, but later operations lost
access to ZFS binaries and other files from the live system.

**Root cause.** Child datasets defaulted to `canmount=on`. When mounted over
the target tree, a child such as `usr` mounted over the live `/usr`, hiding
the binaries that the install shell was still using.

**Fix.** Keep `canmount=noauto` during dataset creation so mounting a child at
`/usr` cannot shadow the live installer's ZFS binaries. After importing the pool
with `-R /mnt`, set each child dataset back to `canmount=on` and mount the root
BE plus all datasets. The active altroot puts child mountpoints under `/mnt`,
not over the live system. This leaves the root BE at `canmount=noauto` while
allowing Void's boot-time `zfs mount -a -l` to mount the children. ZFS children
do not need fstab entries; the ESP remains in `/etc/fstab`.

---

## 11. Tar stream corruption

**Problem.** The live root could not be extracted reliably into the new root;
the archive stream was corrupted.

**Root cause.** `2>&1 |` combined the producer's diagnostics with tar's binary
archive stream. The receiving tar then read diagnostic text as archive data.

**Fix.** Keep producer stderr out of the pipe and preserve ownership with
`--numeric-owner`. Follow upstream Void's `copy_rootfs` tar pattern:
`--one-file-system` avoids traversing separately mounted source subtrees while
archiving `/`, including the target ZFS hierarchy under `/mnt` and live mounts.
The local pipeline excludes only `/sys`, because volatile sysfs metadata can
make GNU tar report that the directory changed even when `--one-file-system`
skips traversal. Strict `set -euo pipefail` correctly surfaced the producer's
nonzero status; it remains enabled. The extractor is unchanged, and
`/var/db/xbps` is copied naturally. This fix has not yet been validated by a
rerun. The ESP contents are installed separately, including the
`EFI/BOOT/BOOTX64.EFI` fallback image.

---

## 12. Missing EFI fallback directory

**Problem.** Copying `BOOTX64.EFI` failed because
`/mnt/boot/efi/EFI/BOOT` did not exist.

**Root cause.** Only the ZFSBootMenu directory had been created before the
fallback copy.

**Fix.** Create `/mnt/boot/efi/EFI/BOOT` before copying the fallback EFI image.
ESP setup and the ZFSBootMenu EFI downloads now complete. The ESP is the only
filesystem listed in fstab; ZFS datasets are managed by the pool.

---

## 13. Chroot package reconfiguration

**Problem.** A previous install run failed at chroot package reconfiguration
with `xbps-reconfigure -fa`.

**Root cause.** A prior tar exclusion of `/var/db/xbps` left the chroot without
the per-package plist metadata that `xbps-reconfigure -fa` needs. The
`/dev/pts` and `/dev/shm` mounts were removed because `xchroot`'s recursive
`--rbind /dev` already propagates them; `/run` is mounted separately as tmpfs.

**Fix.** Remove the `/var/db/xbps/*` tar exclusion so the package database is
preserved. The tar copy follows upstream Void's `copy_rootfs` pattern while
excluding only `/sys`, whose volatile metadata change was surfaced by strict
`pipefail`. Exactly one
`xbps-reconfigure -fa` remains, after locale setup, running directly under
`set -euo pipefail`; its stdout and stderr are captured by the SSH wrapper in
`.build/void-server-install/run.log`. The separate
`xbps-reconfigure -f glibc-locales` is redundant because the all-package
reconfigure runs after locale setup. The final redundant `xbps-reconfigure -fa`
is also removed because `xbps-install -Syu nodejs curl` configures those
packages. The full isolated install and code-server smoke passed before the
final debug-marker cleanup and xbps simplification; the exact final source was
not rerun.

---

## 14. Code-server home and default data paths

**Current configuration.** The code-server executable is installed at
`/home/<primary_user>/.share/code-server`. The runit service sets
`HOME=/home/<primary_user>` and launches that binary while preserving the
loopback bind address `127.0.0.1:8080`.

**Path behavior.** The service does not set custom config, user-data, or
extensions paths. Code-server therefore uses its default locations under
`HOME`, with config at `$HOME/.config/code-server/config.yaml`; the binary's
`.share` installation location does not relocate those data directories. The
code-server smoke passed before the final debug-marker cleanup and xbps
simplification; the exact final source was not rerun.

---

## 15. Mounted ESP tar safety and ZFS pool discovery

**Tar behavior.** The live root is extracted into `/mnt` after mounting the
target ESP at `/mnt/boot/efi`. The tar pipeline follows upstream Void's
`copy_rootfs` pattern. `--one-file-system` prevents traversal into separately
mounted source subtrees, including target ZFS under `/mnt` and other live
mounts; only `/sys` is explicitly excluded because GNU tar can report volatile
sysfs metadata changes even when traversal is skipped. Strict `pipefail`
remains enabled, the extractor is unchanged, and `/var/db/xbps` is copied
naturally. The target ESP receives the ZFSBootMenu EFI files separately,
including the fallback image at `EFI/BOOT/BOOTX64.EFI`.

**Pool/cache behavior.** The ESP is the only filesystem listed in fstab; ZFS
datasets are managed by the pool. No `zpool set cachefile` command is used.
ZFSBootMenu discovers and imports the pool itself, and the install plan exports
the pool at completion, removing it from the cache file. The latest fresh-qcow
run failed at tar because `/sys` changed while being read. The updated tar
producer has not been validated by a rerun.

---

## 16. Fresh isolated disk and partition setup

**Retry note.** The installer uses a simple, destructive reset on the selected
install disk. For a fresh-qcow retry, or if discard and its GPT fallback did not complete, delete
`.build/void-server-install/disk.qcow2` before retrying. Successful isolated
runs preserve the final qcow2 because `keep_disk=true`.

**Partition setup.** The plan runs `zpool labelclear -f "$disk_path" || true`
followed by `blkdiscard -f "$disk_path" || sgdisk -go "$disk_path"`. This
destructive reset is intended only for the selected install disk; ensure that
`boot_disk` identifies the disk you intend to erase. The QEMU wrapper enables
`discard=unmap` on the virtio qcow2 disk so guest discard can be passed through.
`blkdiscard -f` disables blkdiscard's exclusive-access guard and is not secure
erasure. If discard is unsupported or fails, the plan resets the GPT with
`sgdisk -go`. It uses separate `sgdisk` commands to create a 550M
ESP (type `ef00`) and a ZFS partition using the rest of the disk except the
final 10M (type `bf00`). There is no swap partition. `partprobe` and
`udevadm settle` refresh the guest's partition view before formatting the ESP
and creating the pool.

**Hostid.** `zgenhostid -f abadf00d` replaces the live ISO's existing
`/etc/hostid`, and the installer copies that value into `/mnt/etc/`. Hostids
should be unique per machine; this fixed value is the user's choice for their
single target machine and should not be reused on other systems.

This concise setup has not yet been validated by a full install run.

---

## 18. ZFSBootMenu EFI downloads corrupted by fetch output redirection (resolved)

**Problem.** The ZFSBootMenu EFI paths contained short progress text instead of
bootable images, and a large `efi` file appeared in the repository root on the
9p share.

**Root cause.** `xbps-uhelper fetch URL` downloads the file into its current
working directory using the URL basename (`efi`) and writes progress to
stdout. Redirecting stdout to `VMLINUZ.EFI` and `VMLINUZ-BACKUP.EFI` therefore
put progress text in both ESP files while leaving the actual download as a root
`efi` artifact.

**Resolution.** The earlier redirect bug is resolved by installing `curl` in
the live guest prerequisites before running the install plan. The installer
uses `curl -fL -o` to download directly to
`/mnt/boot/efi/EFI/ZBM/VMLINUZ.EFI`, checks that the file is nonempty, and copies
it to `VMLINUZ-BACKUP.EFI`. The `EFI/BOOT/BOOTX64.EFI` fallback copy still runs
afterward. Curl's failure-on-HTTP-error option and the plan's `set -euo
pipefail` make download failures abort the install. The former `xbps-uhelper`
staging workaround is no longer used.

---

## 17. Live installer hostid already exists

**Problem.** The live ISO already provides `/etc/hostid`, so plain `zgenhostid`
would stop with `/etc/hostid: File exists`.

**Root cause.** The live ISO already provides `/etc/hostid`, so plain
`zgenhostid` exits with EEXIST instead of replacing it.

**Fix.** Run `zgenhostid -f abadf00d` before pool creation. The plan then copies
that hostid with `cp /etc/hostid /mnt/etc/`, ensuring the pool-creation hostid
is persisted in the installed target. Hostids should be unique; the user chose
this fixed value for their single target machine. The revised disk setup has
not been validated by a full install run.
