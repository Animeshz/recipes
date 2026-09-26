# void-iso — Troubleshooting Log

Problems encountered making the `void-iso` recipe build a bootable Void ISO
from a macOS host under QEMU, and how each was resolved. Entries describe
constraints that still hold in the current code.

**Final verified state**

```
.build/void-iso/void-live-x86_64-base.iso
  size    1,584,496,640 bytes
  type    ISO 9660 'VOID_LIVE' (bootable)
  layout  boot/isolinux + boot/grub/efibootimg + LiveOS/squashfs.img
  sha256  fb150e30f60113fc251201f253c587fc0452e161433d42089e30fc550dca039f
  run     3127s, 0 errors, peak guest RSS 1.95 GB
```

**Architecture in one glance**

```
9p share (the repo)          source, checkout, xbps caches, final ISO
attached 20 GB disk          mklive's build dir (ROOTDIR=/build), discarded per run
guest internal fs            the OS, and Docker's data-root
```

**Summary**

| # | Problem | Root cause | Fix |
|---|---|---|---|
| 1 | `Package 'nickel' not found in repository pool` | Void has no nickel package | dropped from ISO packages; served from a Docker image |
| 2 | `invalid accelerator hvf` / `unable to find CPU model 'host'` | HVF cannot accelerate x86_64 on Apple Silicon; `-cpu host` is invalid under TCG | arch-aware accel/CPU selection |
| 3 | `failed to mount … fstype: overlay … invalid argument` | `overlay2` nests on the live ISO's own overlayfs root | `storage-driver: vfs` |
| 4 | `mkiso.sh: line 5: ./lib.sh: No such file` | mkiso.sh sources `./lib.sh` relative to cwd | run it with cwd = the checkout |
| 5 | `unrecognized subcommand 'nickel'` | the image's ENTRYPOINT is already `nickel` | dropped the extra word in the shim |
| 6 | `service docker not in /etc/sv` | `mklive -S` needs the package to provide `/etc/sv/<svc>` | docker in **both** packages and services |
| 7 | `xbps [unpack] … Operation not permitted` | `security_model=none` gives no ownership semantics | `security_model=mapped-xattr` |
| 8 | Failure hidden for five minutes | sentinel ended in `rm -f`, masking its own error | `sudo touch … && sudo rm -f …` |
| 9 | `fatal: detected dubious ownership` | repo on the share is owned by the host uid | `GIT_CONFIG_*` → `safe.directory=*` |
| 10 | Died at exactly 91 s, every run, exit 0 | `ssh` forwarded stdin and ate the piped script | `ssh -n` |
| 11 | `failed to start daemon: … volume store metadata database … invalid argument` | bbolt mmaps `metadata.db`; 9p has no mmap | Docker data-root must be guest-local |
| 12 | Build ran out of space, then `unmount … not mounted` | build dir on the RAM-backed root | 20 GB disk + `ROOTDIR=/build` |
| 13 | `xbps` stuck in `D`, `wchan=p9_client_rpc` | QEMU's `mapped-xattr` 9p server wedged | moved heavy unpacking off 9p |
| 14 | ~95 MB re-downloaded every run | guest prereqs cached inside the VM | `/etc/xbps.d/10-cache.conf` + `XBPS_CACHEDIR` |
| 15 | `Permanently added …` on every connection | `UserKnownHostsFile=/dev/null` persists nothing | `-o LogLevel=ERROR` |

---

## 1. `ERROR: Package 'nickel' not found in repository pool.`

**Problem.** mklive aborted at `[4/12]`, so no ISO was produced.

**Root cause.** Void does not package `nickel`. It was listed in the ISO's
`packages`, and mklive treats a missing package as fatal.

**Fix.** Removed `nickel` from the ISO package list. Nickel is instead served
to the guest from the container image
`ghcr.io/tweag/nickel:1.15.1-x86_64`, wrapped by a shim in `/usr/local/bin`:

```sh
exec docker run --rm -i -v "$PWD:$PWD" -w "$PWD" ghcr.io/tweag/nickel:1.15.1-x86_64 "$@"
```

---

## 2. `invalid accelerator hvf` + `unable to find CPU model 'host'`

**Problem.**

```
qemu-system-x86_64: invalid accelerator hvf
qemu-system-x86_64: falling back to tcg
qemu-system-x86_64: unable to find CPU model 'host'
```

**Root cause.** Two coupled issues. `-cpu host` means "expose the physical
CPU", which only works with a hardware accelerator. On Apple Silicon an
**x86_64 guest cannot use HVF at all** (wrong architecture), so QEMU fell back
to TCG — where `-cpu host` is meaningless and invalid.

**Fix.** Select accelerator and CPU model from host OS **and** arch:

```sh
case "$(uname -s)/$(uname -m)" in
  Darwin/x86_64) accel="accel=hvf:tcg"; cpu_model="host" ;;
  Linux/x86_64)  accel="accel=kvm:tcg"; cpu_model="host" ;;
  *)             accel="accel=tcg";     cpu_model="qemu64" ;;
esac
```

The rule: `-cpu host` requires host arch == guest arch. Keying on `uname -s`
alone is wrong — it would fail identically on `Linux/aarch64`.

---

## 3. `failed to mount …: fstype: overlay … err: invalid argument`

**Problem.** Docker could not start a container:

```
docker: Error response from daemon: failed to mount /tmp/containerd-mount…:
mount source: "overlay", …, fstype: overlay, …, err: invalid argument
```

This recurred once, after the `vfs` setting was removed in an attempt to "use
sane defaults" — the second time the daemon started and the image **pulled
fine**, failing only when creating a container, with `upperdir`/`workdir`
pointing under `/var/lib/docker/containerd/…/snapshots/`.

**Root cause.** The live ISO's root is **itself overlayfs**. Docker's
`overlay2` (the default) builds an overlay per layer, which would nest
overlay-on-overlay; the kernel rejects that with `EINVAL`.

**Fix.** `storage-driver: vfs` in `/etc/docker/daemon.json`. This is not a
preference — it is a requirement of running Docker on an overlayfs root.

---

## 4. `./.build/void-mklive/mkiso.sh: line 5: ./lib.sh: No such file or directory`

**Problem.** The build died immediately after cloning `void-mklive`.

**Root cause.** `mkiso.sh` uses **relative** paths internally (`. ./lib.sh`,
and later `./mklive.sh`), so it must run with the current directory set to the
checkout. It was being invoked by path from the repo root.

**Fix.** Run it from inside the checkout, with `-I`/`-o` made absolute first so
they still resolve after the `cd`:

```sh
( cd "$build_dir" && ./mkiso.sh "${variant_args[@]}" -- "${mklive_args[@]}" )
```

---

## 5. `error: unrecognized subcommand 'nickel'`

**Problem.** `nickel --version` through the guest shim failed.

**Root cause.** The container image already sets `nickel` as its `ENTRYPOINT`.
The shim passed `nickel` again, so the container ran `nickel nickel …`.

**Fix.** Drop the redundant word — shown correctly in §1.

---

## 6. `ERROR: service docker not in /etc/sv`

**Problem.** mklive aborted at `[5/12]`.

**Root cause.** `mklive -S` enables a service by symlinking
`<rootfs>/etc/sv/<service>`, and **dies if it is absent**:

```sh
if ! [ -e $ROOTFS/etc/sv/$service ]; then die "service $service not in /etc/sv"; fi
```

`/etc/sv/docker` is provided by the `docker` **package**. Listing a service
does not install its package.

**Fix.** Docker appears in **both** `packages` and `services`:

| packages | services | result |
|---|---|---|
| yes | yes | installed and enabled ✅ |
| yes | no | installed, never started |
| no | yes | `die "service docker not in /etc/sv"` |

---

## 7. `xbps-triggers: [unpack] failed to extract file './var/db/xbps/triggers': Operation not permitted`

**Problem.**

```
ERROR: xbps-triggers-0.131_1: [unpack] failed to extract file `./var/db/xbps/triggers': Operation not permitted
ERROR: Transaction failed! see above for errors.
ERROR: Failed to install required software, exiting...
```

**Root cause.** The 9p share used `security_model=none`, under which QEMU
passes the host identity through and **never fabricates ownership**. xbps must
`chown`/`chmod` every file it unpacks, so the operation has nothing to succeed
against and fails with `EPERM`.

**Fix.** `security_model=mapped-xattr`, which emulates uid/gid in host xattrs so
`chown` "succeeds". This is the current setting — but see §13 for why it alone
is not sufficient.

---

## 8. The failure that hid for five minutes

**Problem.** The build appeared healthy, then failed somewhere confusing
minutes later, with no indication of the real cause.

**Root cause.** The writability sentinel ended in `rm -f`:

```
line 14: Permission denied      ← the actual failure, unnoticed
```

`printf … > .write-test; rm -f .write-test` — the shell's exit status is
`rm`'s, which succeeded, so `set -e` never fired and the run continued on a
broken assumption.

**Fix.** Chain it so failure propagates, as the user that matters:

```sh
sudo touch /mnt/recipes/$workdir/.write-test && sudo rm -f /mnt/recipes/$workdir/.write-test
```

General lesson: **never let a diagnostic's own cleanup become the exit status.**

---

## 9. `fatal: detected dubious ownership in repository at '/mnt/recipes/…/void-mklive'`

**Problem.** The in-guest clone failed; `make` reported `Error 128`.

**Root cause.** Git's CVE-2022-24765 guard refuses to operate on a repository
whose owner differs from the current user. The checkout sits on the 9p share,
so the guest (as root) sees it owned by the host uid.

**Fix.** Declare the shared tree trusted without leaving persistent config:

```sh
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
```

---

## 10. Died at exactly 91 seconds, every single run

**Problem.** The build reliably stopped at ~91 s during the "waiting for guest
sshd" loop:

```
void-iso: waiting for guest sshd (elapsed 91s; …)
qemu-system-x86_64: terminating on signal 15 from pid 53966
```

No error message, and `make` reported exit 0. It looked like an external
interrupt, but reproduced without any Ctrl-C.

**Root cause.** `ssh` forwards stdin to the remote command, and **`make` feeds
the plan to bash over a pipe**. bash was reading its own script from stdin, so
each loop iteration's `ssh` consumed script text. After ~30 iterations bash hit
**EOF**, which it treats as end-of-script: it exited 0, and the `EXIT` trap
killed QEMU.

The decisive clue: the *identical plan run from a file* (`bash /tmp/plan.sh`)
sailed past 91 s and reached the Docker step. A file descriptor is seekable, so
nothing could steal it.

**Fix.** `ssh -n` on every invocation:

```sh
ssh_opts=( -n -o StrictHostKeyChecking=no … )
```

The idiomatic fix for ssh-in-a-loop, and here essential because the script
itself arrives on stdin.

---

## 11. `failed to start daemon: … volume store metadata database … invalid argument`

**Problem.** With Docker's data-root pointed at the share, the daemon created
its directory skeleton and then died. The socket appeared and vanished, so the
image pull failed with `Cannot connect to the Docker daemon`.

**Root cause.** Captured by running each driver in the foreground:

```
failed to start daemon: error while opening volume store metadata database
  (…/volumes/metadata.db): invalid argument
```

identical for `vfs`, `overlay2` **and** `fuse-overlayfs` — so the storage
driver was irrelevant. `volumes/metadata.db` is a **bbolt** database, which
**mmaps** its file, and **9p has no mmap support**, so the map returns `EINVAL`
and the daemon aborts.

**Fix.** The Docker data-root must live on the guest's own filesystem. (Two
earlier hypotheses were wrong: "it's the storage driver" and "it's chown".
Only capturing the real error settled it.)

---

## 12. The build ran out of space, then failed to unmount

**Problem.**

```
umount: /var/tmp/mklive-build.pRhle/image/rootfs/sys: not mounted
ERROR: failed to unmount /var/tmp/mklive-build.pRhle/image/rootfs/sys/
make: *** [Makefile:8: void-iso] Error 1
```

**Root cause.** mklive's build directory was on the guest's RAM-backed root
(`ROOTDIR=/var/tmp`). The rootfs (~2 GB) plus squashfs staging (~1 GB) exceeded
the ~4 GB writable root; the unmount error above is the cascade.

**Fix.** Attach a **20 GB qcow2**, format it ext4, mount at `/build`, and point
mklive there via the variable it honours (`mktemp --tmpdir="$ROOTDIR"`):

```sh
qemu-img create -f qcow2 "$workdir/build-disk.qcow2" 20G     # host, if absent
… -drive "file=$build_disk,if=virtio,format=qcow2"           # attached to guest
sudo mkfs.ext4 -F /dev/vda; sudo mount /dev/vda /build       # guest
cd /mnt/recipes && sudo env ROOTDIR=/build make void-iso     # mklive builds there
```

The disk is a per-run scratch device: created if absent and removed by the
`EXIT` trap, so nothing accumulates across builds.

---

## 13. `xbps` wedged: `D` state, `wchan=p9_client_rpc`

**Problem.** The build stalled with no output; QEMU spun at ~72 % CPU doing
nothing useful.

```
log size: 232998 → 232998 bytes in 20s     ← not progressing
guest load average: 1.00                    ← not busy
guest mem: 876/1969 used                    ← no memory pressure
guest dmesg: nothing for the last 33 min    ← no OOM, no kernel errors

xbps pid 3795: state = D
               wchan = p9_client_rpc         ← blocked on a 9p RPC forever
```

**Root cause.** QEMU's 9p server stopped answering. With
`security_model=mapped-xattr` on a **macOS host**, the xattr emulation path
wedges under sustained heavy unpacking, and the guest's client then blocks
uninterruptibly in `p9_client_rpc`. This is why it got *further* than
`security_model=none` (which failed fast with `EPERM`, §7) but still could not
finish.

**Fix.** Stop asking 9p to do the heavy work. The build directory — the thing
being unpacked file-by-file — moved to the attached disk via `ROOTDIR` (§12),
leaving the share to hold only what it is good at: source, the checkout, the
caches, and the final ISO.

---

## 14. ~95 MB re-downloaded on every run

**Problem.** Repeat builds re-downloaded the guest's prerequisite packages even
with a populated share cache.

**Root cause.** mklive always caches — it passes `-c "$XBPS_CACHEDIR"` to
`xbps-install`. **Our own** prerequisite install did not:

```sh
sudo xbps-install -Syu xbps && sudo xbps-install -Sy git jq … docker
```

so xbps used its default `/var/cache/xbps` **inside the guest**, on the
RAM-backed root, destroyed with the VM. The share cache we were watching
belonged to mklive, which is why it grew while prereqs kept re-downloading.

**Fix.** Configure the guest's cache globally, and cover mklive — which passes
`-c` explicitly and so ignores the config — through the environment variable it
reads (`: ${XBPS_CACHEDIR:=…}`):

```sh
# in the guest
'cachedir=/mnt/recipes/…/xbps-cachedir'  >  /etc/xbps.d/10-cache.conf

# in the plan, before invoking mkiso.sh
export XBPS_CACHEDIR="$PWD/.build/void-iso/xbps-cachedir"
export XBPS_HOST_CACHEDIR="$XBPS_CACHEDIR"
```

---

## 15. `Permanently added '[127.0.0.1]:2222' … to the list of known hosts` on every connection

**Problem.** The warning repeats ~7 times per run.

**Root cause.** By design we use `-o UserKnownHostsFile=/dev/null`, so no host
key is ever persisted; every connection therefore sees a brand-new host and
re-announces it.

**Fix.** `-o LogLevel=ERROR` in `ssh_opts` — keeps genuine errors, suppresses
the notice. (The wait-loop ssh also passes `-q`, which is why it never printed
it.)

---

## Remaining, non-fatal

**`ERROR: Package 'dosfstools' already installed.`** — the live image already
ships `dosfstools`, so listing it in `guest_packages` makes xbps emit an
error-level message. Harmless (the transaction continues), but noisy. Either
drop it — making that dependency implicit, like `dracut`/`e2fsprogs` — or keep
it and accept the line.

**`WARNING: tzdata-2025a_1: invalid provides: py3:tzdata-2025a`** — upstream
package metadata quirk in Void's `tzdata`, unrelated to the recipe.

---

## Methodology notes

Four things did most of the work in finding these.

**1. Capture the actual error; do not infer it.** Two of the longest detours
were wrong inferences stated confidently — "it's the storage driver" and "it's
chown" for Docker (§11). Running `dockerd` in the foreground per driver
produced the real message in a single boot.

**2. Compare against a known-good baseline.** Diffing the running plan against
a previously successful one surfaced a silently mutated line (a lost closing
quote) and a stray duplicated tail — corruption that reading the final file did
not make obvious.

**3. Distinguish "piped" from "file".** The 91-second death (§10) only
reproduced under `make`, because `make` feeds the script to bash on stdin. Any
bug that depends on how the script is *delivered* rather than what it contains
looks intermittent; comparing the two invocation styles isolated it at once.

**4. Read the kernel, not the application.** `wchan=p9_client_rpc` (§13)
pointed straight at the 9p layer, while the application-level symptom was
merely "no output". `dmesg`, `/proc/<pid>/wchan` and process state (`D`) are
cheap and decisive.
