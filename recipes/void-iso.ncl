let qemu = import "../lib/void-qemu.ncl" in
let base = import "../modules/void-iso.ncl" in
{
  module | not_exported = base & {
    packages = ["docker", "fd", "git", "inxi", "ripgrep", "zfs", "openssh"],
    services = ["docker", "sshd"],
  },
  default = module.plan,
  isolated = qemu.wrap module.plan {
    id = "void-iso",
    seed = "https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso",
    uefi = false,
    qemu = "qemu-system-x86_64",
    ram = "8192",
    cpus = "8",
    display = "none",
    ssh_port = "2222",
    user = "anon",
    password = "voidlinux",
    share_path = "$PWD",
    share_tag = "recipes",
    guest_mount = "/mnt/recipes",
    disk_size = "20G",
    packages = "ca-certificates git xz curl gzip",
    env = "",
  },
}
