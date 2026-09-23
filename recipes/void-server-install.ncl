let m = import "../modules/void-server-install.ncl" in
m & {
  micro_sd_disk = "/dev/disk/by-id/microsd-1",
  be = "void-server",
}
