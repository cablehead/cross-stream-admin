# git-host gateway, smart-HTTP git over http-nu, gatewaying to git-http-backend (CGI).
#
# Bare repos live at /home/app/git/<label>.git. A `git push` speaks git's smart-HTTP
# protocol; we shell out to git-http-backend for the actual pack negotiation and stream
# its binary CGI output back out, splitting the CGI header block from the packfile body.
#
# Push auth: HTTP Basic. The per-site token (sent as the Basic username OR password) is
# looked up in tokens.json -> the label it may push to. A token may only touch its label.
#
# Run standalone for the scratch proof:
#   http-nu 127.0.0.1:<port> /home/app/git-host/serve.nu
# Eventually: bound to /run/sites/git.sock as the reserved `git` label.

const GIT_ROOT = "/home/app/git"
const BACKEND = "/usr/lib/git-core/git-http-backend"
const TOKENS = "/home/app/git/tokens.json"
const KEY_TOPIC = "site.token"

# A push key is one frame on `site.token`, appended by the admin over this process's own
# store socket. Its meta carries everything about the key except the key:
#   {label, name, hash, suffix, created}
# `hash` is sha256 of the secret. The secret itself is never written down, so this store,
# a backup of it, or a screenshot of the admin page cannot be pushed with. A label may have
# any number of keys, which is what makes rolling one a non-event: add, deploy, remove.
#
# The `try` matters. `.cat` only exists when http-nu is run with --store, so a tenant whose
# unit predates that flag falls back to the legacy map below instead of failing to serve.
def load-keys [] {
  try {
    .cat --topic $KEY_TOPIC
      | where {|f| ($f.meta?.hash? | default "" | is-not-empty) }
      | each {|f| {label: $f.meta.label, hash: $f.meta.hash} }
  } catch { [] }
}

# tokens.json: { "<token>": "<label>", ... }. The pre-store shape, plaintext and keyed by the
# secret. Read-only here, and only until every tenant has run migrate-tokens.nu.
def load-tokens [] { if ($TOKENS | path exists) { open --raw $TOKENS | from json } else { {} } }

# The label a single presented secret may push to, or null. Hashed lookup first, then the
# legacy plaintext map.
def label-for-secret [secret: string, keys: list] {
  if ($secret | is-empty) { null } else {
    let hit = ($keys | where hash == ($secret | hash sha256) | get -o 0.label)
    if ($hit | is-not-empty) { $hit } else { (load-tokens) | get -o $secret }
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

# The label a Basic-auth token is allowed to push to, or null. The token may arrive as the
# Basic username (https://<token>@host) or the password (https://x:<token>@host).
def token-label [req: record] {
  let h = ($req.headers | get -o authorization | default "")
  if not ($h | str starts-with "Basic ") { return null }
  let decoded = (try { $h | str replace 'Basic ' '' | decode base64 | decode utf-8 } catch { "" })
  let parts = ($decoded | split row ':')
  let keys = (load-keys)
  [($parts.0? | default "") ($parts.1? | default "")]
    | each {|c| label-for-secret $c $keys }
    | where {|l| ($l | is-not-empty) }
    | get -o 0
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

{|req|
  let body = $in
  let label = (path-label $req.path)
  if ($label | is-empty) {
    resp "not found" 404 {}
  } else {
    let allowed = (token-label $req)
    if ($allowed == null) {
      resp "authentication required" 401 {"WWW-Authenticate": 'Basic realm="git"'}
    } else if ($allowed != $label) {
      resp $"token not authorized for label ($label)" 403 {}
    } else if not ($"($GIT_ROOT)/($label).git" | path exists) {
      resp $"no such repo: ($label).git" 404 {}
    } else {
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
  }
}
