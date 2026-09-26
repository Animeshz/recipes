let m = import "../modules/void-iso.ncl" in
m & {
  packages = ["docker", "fd", "git", "inxi", "ripgrep", "zfs"],
  services = ["docker"],
  isolate = {
    enable = true,
    vm_ram = "8192",
  },
}
