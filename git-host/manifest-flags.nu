# Resolve a cross-stream.nuon manifest into http-nu flags. Called by ce-site-deploy with
# $env.MANIFEST, $env.STORE_DIR and $env.WORKTREE set. Prints the flag string on stdout and
# nothing else, because ce-site-deploy captures stdout straight into HTTPNU_FLAGS; anything
# to say to the pusher goes to stderr, which lands in their `git push` output.
#
# A repo declares INTENT. We read only the known keys and build every path ourselves, so a
# pushed repo can never inject raw args like --expose / --tls / -c. `open` on a .nuon file is
# data deserialization, not evaluation, so it is safe.
#
# The checks here duplicate validate-manifest.nu on purpose. That one runs in pre-receive and
# gives better errors; this one is the gate that actually holds, because a site deployed from
# a public git URL never passes through the hook.

let m = (try { open ($env.MANIFEST) } catch { {} })

let services = (($m | get -o services | default false) == true)
let store = ((($m | get -o store | default false) == true) or $services)

mut f = []
if $store { $f = ($f | append $"--store ($env.STORE_DIR)") }
if $services { $f = ($f | append "--services") }
if (($m | get -o datastar | default false) == true) { $f = ($f | append "--datastar") }

# plugins: a bare name is a stock plugin from the image, anything with a "/" is a binary
# committed in the repo, resolved under the work-tree. A bad entry is skipped with a loud
# warning rather than failing the deploy, matching how a missing serve.nu is handled.
def warn [msg: string] { print -e $"post-receive: WARNING ($msg)" }

let plugins = ($m | get -o plugins | default [])
if ($plugins | describe | str starts-with "list") {
  for p in $plugins {
    if ($p | describe) != "string" {
      warn "skipping a plugins entry that is not a string"
    } else if ($p | is-empty) {
      warn "skipping an empty plugins entry"
    } else if ($p | str starts-with "/") {
      warn $"skipping absolute plugins entry ($p), use a stock name or a path inside your repo"
    } else if ($p =~ '(^|/)\.\.(/|$)') {
      warn $"skipping plugins entry containing '..': ($p)"
    } else if (($p =~ '^[A-Za-z0-9._/-]+$') == false) {
      warn $"skipping plugins entry with unsupported characters: ($p)"
    } else {
      let repo_local = ($p | str contains "/")
      if $repo_local and ((($p | path basename) =~ '^nu_plugin_[A-Za-z0-9_-]+$') == false) {
        warn $"skipping ($p): a plugin committed in your repo must be named nu_plugin_*"
      } else {
        let abs = (if $repo_local { $env.WORKTREE | path join $p } else { $"/usr/local/bin/nu_plugin_($p)" })
        if ($abs | path exists) {
          $f = ($f | append $"--plugin ($abs)")
        } else if $repo_local {
          warn $"plugin ($p) is not in the pushed tree, skipping it. Is it committed?"
        } else {
          warn $"no stock plugin named ($p) in this image, skipping it"
        }
      }
    }
  }
}

$f | str join " "
