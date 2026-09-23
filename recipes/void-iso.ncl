let m = import "../modules/void-iso.ncl" in
m & {
  output = "void-live-animesh-%{m.arch}-%{m.variant}.iso",
}
