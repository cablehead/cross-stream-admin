# git-host gateway, smart-HTTP git over http-nu, gatewaying to git-http-backend (CGI).
#
# Bare repos live at /home/app/git/<label>.git. A `git push` speaks git's smart-HTTP
# protocol; we shell out to git-http-backend for the actual pack negotiation and stream
# its binary CGI output back out, splitting the CGI header block from the packfile body.
#
# Push auth: HTTP Basic. The token (sent as the Basic username OR password) is looked up by
# its hash; the key it belongs to names the sites it may push to, or every site. A key with
# `manage` also makes a site when it pushes to one that doesn't exist yet, and the site joins
# the key's own list.

# Run standalone for the scratch proof:
#   http-nu 127.0.0.1:<port> /home/app/git-host/serve.nu
# Eventually: bound to /run/sites/git.sock as the reserved `git` label.

use site.nu *

const BACKEND = "/usr/lib/git-core/git-http-backend"
const TOKENS = "/home/app/git/tokens.json"
const KEY_TOPIC = "site.token"

# A push key is one frame on `site.token`, appended by the admin over this process's own
# store socket. Its meta carries everything about the key except the key:
#   {name, hash, suffix, created, every, sites, manage}
# `hash` is sha256 of the secret. The secret itself is never written down, so this store,
# a backup of it, or a screenshot of the admin page cannot be pushed with. `every: true` lets
# the key push to every site, including ones made after it; otherwise `sites` lists the labels
# it may push to. A key minted when keys belonged to one site carries `label` instead, which
# reads as `sites: [label]`. Any number of keys may reach a site, which is what makes rolling
# one a non-event: add, deploy, remove.
#
# The `try` matters. `.cat` only exists when http-nu is run with --store, so a tenant whose
# unit predates that flag falls back to the legacy map below instead of failing to serve.
def key-scope [meta: record] {
  let manage = ($meta.manage? | default false)
  if ($meta.every? | default false) { {every: true, sites: [], manage: $manage} } else {
    let legacy = (if ($meta.label? | is-empty) { [] } else { [$meta.label] })
    {every: false, sites: ($meta.sites? | default $legacy), manage: $manage}
  }
}

def load-keys [] {
  try {
    .cat --topic $KEY_TOPIC
      | where {|f| ($f.meta?.hash? | default "" | is-not-empty) }
      | each {|f| {id: $f.id, name: ($f.meta.name? | default "unnamed"), hash: $f.meta.hash} | merge (key-scope $f.meta) }
  } catch { [] }
}

# tokens.json: { "<token>": "<label>", ... }. The pre-store shape, plaintext and keyed by the
# secret. Read-only here, and only until every tenant has run migrate-tokens.nu.
def load-tokens [] { if ($TOKENS | path exists) { open --raw $TOKENS | from json } else { {} } }

# Where a single presented secret may push, as {every, sites}, or null. Hashed lookup first,
# then the legacy plaintext map.
def scope-for-secret [secret: string, keys: list] {
  if ($secret | is-empty) { null } else {
    let hit = ($keys | where hash == ($secret | hash sha256) | get -o 0)
    if ($hit | is-not-empty) { $hit | select id name every sites manage } else {
      let label = ((load-tokens) | get -o $secret)
      if ($label | is-empty) { null } else { {id: null, name: "legacy", every: false, sites: [$label], manage: false} }
    }
  }
}

def resp [body, status: int, headers: record] {
  $body | metadata set { merge {'http.response': {status: $status, headers: $headers}} }
}

# The label a request targets: first path segment with a trailing `.git` stripped.
#   /scratch.git/info/refs -> "scratch"
def path-label [path: string] {
  let seg = ($path | str replace --regex '^/+' '' | split row '/' | get 0? | default "")
  $seg | str replace --regex '\.git$' ''
}

# Where the Basic-auth token may push, one scope per credential that matched. The token may
# arrive as the Basic username (https://<token>@host) or the password (https://x:<token>@host).
def token-scopes [req: record] {
  let h = ($req.headers | get -o authorization | default "")
  if not ($h | str starts-with "Basic ") { return [] }
  let decoded = (try { $h | str replace 'Basic ' '' | decode base64 | decode utf-8 } catch { "" })
  let parts = ($decoded | split row ':')
  let keys = (load-keys)
  [($parts.0? | default "") ($parts.1? | default "")]
    | each {|c| scope-for-secret $c $keys }
    | where {|s| $s != null }
}

# Split git-http-backend's CGI output: a \r\n-delimited header block, a \r\n\r\n blank
# line, then the (binary) body. Returns { status, headers, body }.
def split-cgi [raw: binary] {
  let sep = 0x[0d 0a 0d 0a]
  let idx = ($raw | bytes index-of $sep)
  if $idx < 0 {
    { status: 200, headers: {}, body: $raw }
  } else {
    let head_txt = ($raw | bytes at 0..<$idx | decode utf-8)
    let total = ($raw | bytes length)
    let bstart = ($idx + 4)
    let body = (if $bstart >= $total { 0x[] } else { $raw | bytes at $bstart.. })
    let pairs = ($head_txt | split row "\r\n" | where {|l| ($l | str trim) != "" } | parse "{key}: {value}")
    let status = (
      let s = ($pairs | where key == "Status" | get -o value.0);
      if ($s | is-empty) { 200 } else { $s | str trim | split row ' ' | get 0 | into int }
    )
    let headers = ($pairs | where key != "Status" | reduce --fold {} {|p, acc| $acc | insert $p.key $p.value })
    { status: $status, headers: $headers, body: $body }
  }
}

# Add `label` to the key that made it, so the push that made the site can go on. Frames don't
# change, so this appends the key again with the site added and removes the old frame, as the
# admin does when you change a key's sites. A key that reaches every site needs nothing.
def grant [key: record, label: string] {
  if $key.every { return }
  let old = (.cat --topic $KEY_TOPIC | where id == $key.id | get -o 0)
  if ($old | is-empty) { return }
  let sites = ($key.sites | append $label | uniq | sort)
  .append $KEY_TOPIC --ttl forever --meta ($old.meta | reject -o label | merge {sites: $sites}) | ignore
  .remove $key.id
}

# A push asks for git-receive-pack: first `GET info/refs?service=git-receive-pack`, then
# `POST git-receive-pack`. A fetch asks for git-upload-pack, and never makes a site.
def push? [req: record] {
  (($req.query.service? | default "") == "git-receive-pack") or ($req.path | str ends-with "/git-receive-pack")
}

# Hand the request to git-http-backend and stream its answer back.
def serve-git [req: record, body: any, label: string] {
  # Normalise the body to binary up front. http-nu hands us a *string* when the request
  # body is valid UTF-8 (e.g. a fetch's ASCII pkt-line "want" list) and a *binary* when
  # it isn't (e.g. a push packfile). `bytes length` errors on strings, so deriving
  # CONTENT_LENGTH from the raw body silently yielded 0 for fetches and git-http-backend
  # then read an empty stdin ("the remote end hung up"). Converting once fixes the length
  # AND guarantees the exact same bytes get piped to stdin.
  let bin = ($body | into binary)
  let clen = ($bin | bytes length)
  let qs = ($req.query | items {|k, v| $"($k)=($v)" } | str join "&")
  let env_vars = {
    GIT_PROJECT_ROOT: $GIT_ROOT
    GIT_HTTP_EXPORT_ALL: "1"
    REQUEST_METHOD: $req.method
    PATH_INFO: $"/($req.path | str replace --regex '^/+' '')"
    QUERY_STRING: $qs
    CONTENT_TYPE: ($req.headers | get -o content-type | default "")
    CONTENT_LENGTH: ($clen | into string)
    HTTP_CONTENT_ENCODING: ($req.headers | get -o content-encoding | default "")
    # git protocol v2 negotiation (git 2.18+ default for fetch): git-http-backend
    # promotes HTTP_GIT_PROTOCOL to GIT_PROTOCOL for upload-pack/receive-pack. Without
    # this the client asks for v2 while the backend answers v0 and the fetch stalls.
    HTTP_GIT_PROTOCOL: ($req.headers | get -o git-protocol | default "")
    REMOTE_USER: $label
  }
  let out = (with-env $env_vars { $bin | ^$BACKEND | complete })
  if $out.exit_code != 0 {
    resp $"git-http-backend failed: ($out.stderr)" 500 {}
  } else {
    let r = (split-cgi ($out.stdout | into binary))
    resp $r.body $r.status $r.headers
  }
}

{|req|
  let body = $in
  let label = (path-label $req.path)
  let scopes = (token-scopes $req)
  let reaches = ($scopes | any {|s| $s.every or ($label in $s.sites) })
  let maker = ($scopes | where manage | get -o 0)
  if ($label | is-empty) {
    resp "not found" 404 {}
  } else if ($scopes | is-empty) {
    resp "authentication required" 401 {"WWW-Authenticate": 'Basic realm="git"'}
  } else if ($"($GIT_ROOT)/($label).git" | path exists) {
    if $reaches { serve-git $req $body $label } else { resp $"token not authorized for label ($label)" 403 {} }
  } else if ($maker | is-not-empty) and (push? $req) {
    let failed = (create-site $label $"key ($maker.name)")
    if ($failed | is-not-empty) { resp $failed.error $failed.status {} } else {
      grant $maker $label
      serve-git $req $body $label
    }
  } else if $reaches {
    resp $"no such repo: ($label).git" 404 {}
  } else {
    resp $"token not authorized for label ($label)" 403 {}
  }
}
