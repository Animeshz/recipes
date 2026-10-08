let qemu = import "../lib/void-qemu.ncl" in
let base = import "../modules/void-server-install.ncl" in
{
  module | not_exported = base & {
    boot_disk = "/dev/disk/by-id/microsd-1",
    server_name = "void-server",
    packages = [
      "zfs", "openssh", "chrony", "dhcpcd", "docker", "curl",
      "ca-certificates", "git", "bash", "xz", "gptfdisk", "dosfstools",
      "efibootmgr", "sudo",
    ],
    services = ["sshd", "chronyd", "dhcpcd", "docker", "code-server"],
  },
  module_isolated | not_exported = base & {
    boot_disk = "/dev/vda",
    server_name = "void-server",
    packages = [
      "zfs", "openssh", "chrony", "dhcpcd", "docker", "curl",
      "ca-certificates", "git", "bash", "xz", "gptfdisk", "dosfstools",
      "efibootmgr", "sudo",
    ],
    services = ["sshd", "chronyd", "dhcpcd", "docker", "code-server"],
  },
  default = module.plan,
  isolated = qemu.wrap module_isolated.plan {
    id = "void-server-install",
    seed = ".build/void-iso/void-live-x86_64-base.iso",
    uefi = true,
    qemu = "qemu-system-x86_64",
    ram = "8192",
    cpus = "8",
    display = "none",
    ssh_port = "2223",
    user = "anon",
    password = "voidlinux",
    share_path = "$PWD",
    share_tag = "recipes",
    guest_mount = "/mnt/recipes",
    disk_size = "20G",
    keep_disk = true,
    packages = "jq make xz git gptfdisk dosfstools zfs efibootmgr parted curl",
    env = "VOID_INSTALL_DISK=/dev/vda",
  },
}
