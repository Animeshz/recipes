let m = import "../modules/void-iso.ncl" in
m & {
  packages = ["nickel", "git", "curl", "ca-certificates", "xz"],
  services = ["docker"],
}
