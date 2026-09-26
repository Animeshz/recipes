let m = import "../modules/void-iso.ncl" in
m & {
  packages = ["docker", "git", "zfs"],
  services = ["docker"],
  isolate = {
    enable = true,
  },
}
