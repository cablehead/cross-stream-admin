# Validate a cross-stream.nuon manifest passed as $env.CONTENT. Prints a human reason and
# exits 1 if invalid; exits 0 (silent) if fine. Called by the pre-receive hook.
# `from nuon` is data deserialization (not eval), so untrusted content is safe to parse.
let m = (try { $env.CONTENT | from nuon } catch { print "not valid nuon, expected e.g. { store: true }"; exit 1 })
if (($m | describe | str starts-with "record") == false) { print "must be a record, e.g. { store: true }"; exit 1 }
let known = [store services datastar plugins http_nu]
let bad = ($m | columns | where {|k| $k not-in $known })
if ($bad | is-not-empty) { print $"unknown key\(s\): ($bad | str join ', '), known keys are store, services, datastar, plugins, http_nu"; exit 1 }
for k in ($m | columns | where {|k| $k not-in [plugins http_nu] }) {
  if (($m | get $k | describe) != "bool") { print $"($k) must be true or false" ; exit 1 }
}

# `http_nu` pins the site to one of the http-nu versions this VM's layer carries, under
# /opt/http-nu/<version>/, e.g. { http_nu: "0.19.0" }. Without it the site runs the layer's
# default, which moves only once every site has moved. A pin the layer doesn't carry is
# refused here, with the versions it does carry.
let pin = ($m | get -o http_nu)
if $pin != null {
  let carried = (try { ls /opt/http-nu | where type != symlink and name !~ 'default$' | get name | path basename | sort } catch { [] })
  if (($pin | describe) != "string") or (($pin =~ '^\d+\.\d+\.\d+$') == false) {
    print $"http_nu must be a version string, e.g. { http_nu: \"0.19.0\" }"; exit 1
  }
  if ($carried | is-empty) { print "this VM's layer carries one http-nu only, so it can't be pinned yet: remove http_nu"; exit 1 }
  if $pin not-in $carried { print $"http_nu ($pin) is not on this VM; it carries ($carried | str join ', ')"; exit 1 }
}

# `plugins` is the other non-boolean key: a list of nushell plugins to load. Two forms, told
# apart by whether the entry contains a "/":
#
#   "polars"                  a stock plugin shipped in the image, /usr/local/bin/nu_plugin_polars
#   "bin/nu_plugin_largediff" a binary committed in this repo, relative to the repo root
#
# Either way the deploy builds the absolute path itself and re-checks everything below, because
# a site deployed from a public git URL never passes through this hook.
let plugins = ($m | get -o plugins)
if $plugins != null {
  if (($plugins | describe | str starts-with "list") == false) {
    print 'plugins must be a list, e.g. { plugins: ["polars"] } or { plugins: ["bin/nu_plugin_largediff"] }'; exit 1
  }
  for p in $plugins {
    if (($p | describe) != "string") { print "each entry in plugins must be a string"; exit 1 }
    if ($p | is-empty) { print "a plugins entry is empty"; exit 1 }
    if ($p | str starts-with "/") { print $"plugins entries are a stock plugin name or a path inside your repo, not an absolute path: ($p)"; exit 1 }
    if ($p =~ '(^|/)\.\.(/|$)') { print $"a plugins entry may not contain '..': ($p)"; exit 1 }
    if (($p =~ '^[A-Za-z0-9._/-]+$') == false) { print $"unsupported characters in plugins entry \(letters, digits, . _ - / only\): ($p)"; exit 1 }
    if ($p | str contains "/") {
      if ((($p | path basename) =~ '^nu_plugin_[A-Za-z0-9_-]+$') == false) {
        print $"a plugin binary committed in your repo must be named nu_plugin_*: ($p)"; exit 1
      }
    } else {
      if (($p =~ '^[A-Za-z0-9_-]+$') == false) { print $"not a usable stock plugin name: ($p)"; exit 1 }
      if ($p | str starts-with "nu_plugin_") {
        print $"name a stock plugin without the prefix, e.g. ($p | str replace 'nu_plugin_' '') rather than ($p)"; exit 1
      }
    }
  }
}
