let m = import "../modules/void-iso.ncl" in
m & {
  packages = ["git", "zfs", "docker"],
  services = ["docker"],
  isolate = {
    enable = true,
    keep_vm = true,
    vm_ram = "2048",
    vm_cpus = "8",
  },
}
