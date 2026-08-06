# admin.<tenant>, broker-verified login + site management. Holds NO OAuth secret: only the
# broker's public key + an allowlist. Runs as root (see deploy/admin.service) so it can drive
# git + systemctl; the sites it manages stay DynamicUser-sandboxed (see deploy/site@.service).
#
# Deploy model: PUSH-TO-DEPLOY. "Create site" mints a per-site token + a bare repo at
# /home/app/git/<label>.git with a post-receive hook; each site's push commands live on its
# own page (/s/<label>). The reserved `git` label (git-host.service on /run/sites/git.sock)
# receives the push, checks the tree out into /home/app/sites/<label>/repo and restarts it.
#
# Surface: Stellar tokens via assets/{stellar,base}.css (raw tags styled once) + a thin
# admin.css. Markup is minijinja (templates/*.html), raw table/nav/pre, no bespoke chrome.
const CFG = "/home/app/admin/tenant.json"
const BROKER_PUB = "/home/app/admin/broker-pub.jwk"
const AUTH_DIR = "/home/app/admin/auth"
const STEP = "/usr/local/bin/step"
const REGISTRY = "/home/app/admin/registry.nuon"
const SITES = "/home/app/sites"
const GIT_ROOT = "/home/app/git"
const TOKENS = "/home/app/git/tokens.json"
# Canonical location of the deploy hooks -- every bare repo's `core.hooksPath` points here, so
# editing a hook takes effect on the next push everywhere. Single point of truth: when the layer
# moves the checkout, this is the only line that changes. (ce-boot-config symlinks this path at
# the merged layout /home/app/admin/git-host.)
const HOOKS_DIR = "/home/app/git-host"
const ASSETS = "/home/app/admin/assets"
const TPL = "/home/app/admin/templates"
const SHOTS = "/home/app/admin/screenshots"
const DOCS = "/home/app/admin/docs"
# live log tail: how much backlog to open with, how many rows the panel holds, and how long one
# tail may live before the client reconnects (see logs-stream for why the cap exists)
const LOG_TAIL = 200
const LOG_CAP = 500
const LOG_WINDOW = 900
use /home/app/admin/oauth/lib.nu *
use http-nu/html *
use http-nu/datastar *

def verify-token [token: string, cfg: record] {
  let r = ($token | ^$STEP crypto jwt verify --key $BROKER_PUB --iss $cfg.broker --aud $cfg.tenant | complete)
  if $r.exit_code == 0 { $r.stdout | from json | get payload } else { null }
}

def load-cfg [] { if ($CFG | path exists) { open --raw $CFG | from json } else { null } }
def load-registry [] { if ($REGISTRY | path exists) { open $REGISTRY } else { [] } }
def load-tokens [] { if ($TOKENS | path exists) { open --raw $TOKENS | from json } else { {} } }
def save-tokens [t: record] { $t | to json | save --force $TOKENS; ^chown app:app $TOKENS }

def token-for [label: string] {
  let t = (load-tokens)
  if ($t | is-empty) { null } else { $t | transpose tok lbl | where lbl == $label | get -o tok.0 }
}

def cookie [req: record, name: string] {
  let raw = ($req.headers | get -o cookie | default "")
  if ($raw | is-empty) { "" } else { $raw | parse-cookies | get -o $name | default "" }
}

def resp [body: string, status: int, headers: record] {
  $body | metadata set { merge {'http.response': {status: $status, headers: $headers}} }
}

def parse-form [body: string] {
  if ($body | is-empty) { {} } else {
    $body | split row "&" | reduce --fold {} {|pair, acc|
      let kv = ($pair | split row "=")
      $acc | insert ($kv.0) (($kv.1? | default "") | str replace --all "+" " " | url decode)
    }
  }
}

def valid-label [label: string] {
  ($label =~ '^[a-z0-9][a-z0-9-]{0,31}$') and ($label not-in ["admin" "www" "placeholder" "git"])
}

def load-session [req: record, ss: record] {
  let hash = (cookie $req "session")
  if ($hash | is-empty) { null } else {
    let v = (do $ss.get $hash)
    if ($v | is-empty) { null } else {
      let p = ($v | from json)
      if ("sub" in ($p | columns)) { $p } else { null }
    }
  }
}
def who-of [s: record] { $s.username? | default ($s.sub? | default "?") }

def unit-state [unit: string] { try { ^systemctl show -p ActiveState --value $unit | str trim } catch { "unknown" } }

# Serve a file (asset or screenshot). png-typed dir passed in. basename-guarded. No `return`
#, `return (resp ...)` drops the pipeline metadata, leaking 404s as 200s.
def serve-file [dir: string, prefix: string, path: string, ct: string] {
  let file = ($path | str replace --regex $"^($prefix)" '' | path basename)
  let full = ($dir | path join $file)
  if not ($full | path exists) {
    resp "not found" 404 {}
  } else {
    let cty = (if $ct != "" { $ct } else {
      match ($file | path parse | get extension) {
        "css" => "text/css", "woff2" => "font/woff2", "js" => "text/javascript",
        "png" => "image/png", "svg" => "image/svg+xml", _ => "application/octet-stream"
      }
    })
    open --raw $full | metadata set { merge {'http.response': {status: 200, headers: {"Content-Type": $cty, "Cache-Control": "public, max-age=3600"}}} }
  }
}

# The two git commands, syntax-highlighted by `.md` (one <pre><code>, no wrapper).
def push-commands [remote: string] {
  $"```bash\ngit remote add cross-stream ($remote)\ngit push -u cross-stream main\n```" | .md | get __html
}

# Rows for the dashboard table, as records the template loops over.
def site-records [reg: list, tenant: string] {
  $reg | each {|d| {
    label: $d.label
    host: $"($d.label).($tenant).cross.stream"
    state: (unit-state $"site@($d.label)")
    manage: $"/s/($d.label)"
    note: null
  }}
}

def login-page [reason: string, tenant: string] {
  {tenant: $tenant, user: "", reason: $reason} | .mj $"($TPL)/login.html"
}

def admin-page [user: string, cfg: record, reg: list] {
  let www_target = (try { ls -l /run/sites/www.sock | get target.0 | path basename } catch { "placeholder.sock" })
  let www_state = (if $www_target == "placeholder.sock" { unit-state "site@placeholder" } else { unit-state $"site@($www_target | str replace '.sock' '')" })
  let sites = ([
    ...(site-records $reg $cfg.tenant)
    {label: "www", host: $"www.($cfg.tenant).cross.stream", state: $www_state, manage: null, note: "builtin placeholder"}
    {label: "admin", host: $"admin.($cfg.tenant).cross.stream", state: (unit-state "admin.service"), manage: null, note: "builtin"}
  ])
  {tenant: $cfg.tenant, user: $user, sites: $sites} | .mj $"($TPL)/dashboard.html"
}

# Which http-nu features a site is actually running with, read from the resolved flags the
# hook wrote to its env (source of truth for what's live, post-whitelist).
def site-flags [label: string] {
  let envf = $"($SITES)/($label)/env"
  let s = (if ($envf | path exists) { open --raw $envf } else { "" })
  { store: ($s | str contains "--store"), services: ($s | str contains "--services"), datastar: ($s | str contains "--datastar") }
}

# The left column: every site, as a link that stays on whichever tab you're reading. That's the
# whole mechanism for "keep my tab when I switch site" -- the tab is in the URL, so an ordinary
# anchor carries it. No state, no script, and the back button behaves.
def site-nav [label: string, tab: string, reg: list] {
  $reg | each {|d| {
    label: $d.label
    href: (if $tab == "logs" { $"/s/($d.label)/logs" } else { $"/s/($d.label)" })
    current: ($d.label == $label)
  }}
}

# A site's own page. Two tabs over one template: `detail` (push commands, features, restart) and
# `logs` (the live tail). Also the create-landing -- create redirects to the detail tab.
def site-page [label: string, user: string, cfg: record, tab: string] {
  let token = (token-for $label)
  if ($token == null) {
    resp $"no such site: ($label)" 404 {}
  } else {
    let base = {
      tenant: $cfg.tenant, user: $user, label: $label
      host: $"($label).($cfg.tenant).cross.stream"
      state: (unit-state $"site@($label)")
      tab: $tab
      nav: (site-nav $label $tab (load-registry))
    }
    let page = (if $tab == "logs" {
      # served by http-nu itself (admin.service runs with --datastar), not by this handler
      $base | merge {datastar_js: $DATASTAR_JS_PATH, log_cap: $LOG_CAP}
    } else {
      let remote = $"https://($token)@git.($cfg.tenant).cross.stream/($label).git"
      $base | merge {commands: (push-commands $remote)} | merge (site-flags $label)
    })
    $page | .mj $"($TPL)/site.html"
  }
}

# The tenant-facing guide, rendered straight from docs/site-guide.md through `.md`. The markdown
# is the single source: the site page links here rather than restating it, so there's one copy to
# keep true.
def docs-page [user: string, cfg: record] {
  let src = $"($DOCS)/site-guide.md"
  if not ($src | path exists) {
    resp "guide not found" 404 {}
  } else {
    # `decode utf-8` is load-bearing: `open --raw` hands back a byte stream and plain `open`
    # parses .md into a table, and `.md` accepts neither, only a string.
    {tenant: $cfg.tenant, user: $user, body: (open --raw $src | decode utf-8 | .md | get __html)} | .mj $"($TPL)/docs.html"
  }
}

def caption-for [file: string] { $file | str replace --regex '^[0-9]+-' '' | str replace --regex '\.png$' '' | str replace --all '-' ' ' }

def screenshots-page [user: string, cfg: record] {
  let files = (glob $"($SHOTS)/*.png" | each {|p| $p | path basename } | sort)
  let grid = ($files | each {|f|
    r#'<figure><a href="/screenshots/{{F}}" target="_blank" rel="noopener"><img src="/screenshots/{{F}}" alt="{{CAP}}" loading="lazy"></a><figcaption><small>{{CAP}}</small></figcaption></figure>'#
      | str replace --all "{{F}}" $f | str replace --all "{{CAP}}" (caption-for $f)
  } | str join "\n")
  {tenant: $cfg.tenant, user: $user, count: ($files | length), grid: $grid} | .mj $"($TPL)/screenshots.html"
}

# Mint a token + bare repo + post-receive hook, register, then land on the site's page.
def do-create [label: string, reg: list, tenant: string] {
  let bare = $"($GIT_ROOT)/($label).git"
  if ($label in ($reg | get -o label | default [])) {
    resp $"label ($label) already in use, pick another" 409 {}
  } else if ($bare | path exists) {
    resp $"($bare) already exists on disk" 409 {}
  } else {
    let token = (random chars --length 32)
    let init = (^git init --bare -b main $bare | complete)
    if $init.exit_code != 0 {
      resp $"git init failed: ($init.stderr)" 500 {}
    } else {
      ^git -C $bare config http.receivepack true
      ^git -C $bare config http.uploadpack true
      # one canonical copy of the hooks serves every repo -- no per-repo snapshot to go stale
      ^git -C $bare config core.hooksPath $HOOKS_DIR
      ^chown -R app:app $bare
      save-tokens (load-tokens | insert $token $label)
      $reg | append {label: $label, created: (date now | format date "%Y-%m-%d")} | save --force $REGISTRY
      resp "" 302 {Location: $"/s/($label)"}
    }
  }
}

# A site's live log, as one long-lived SSE read (/s/<label>/logs). The stream IS the state:
# journalctl -f is the only source, the label is the only parameter, and nothing here is shared
# with any other request -- a reconnect just starts a fresh journalctl. Datastar retries the
# fetch on its own, so a dropped connection or a site restart self-heals with no code.
#
# Rows are built with the HTML DSL, which escapes plain strings. That matters: a log line
# carries the request path and Host header of whoever hit the site. Never pass one through
# `{__html:}`, `.md`, or `.highlight` (all of which mean "already sanitized"), and never put one
# in a data-* attribute -- those are Datastar expressions, evaluated, so escaping doesn't cover
# them.
def logs-stream [label: string] {
  # `timeout` is load-bearing, not a safety belt. http-nu does not reap the child when the
  # browser goes away: measured on 0.17.2, a bare `journalctl -f` stayed a live child of the
  # server long after the client disconnected, and a heartbeat write did not change that. So
  # every abandoned panel would hold a tail open until the admin restarts. Capping the child's
  # life bounds that to one window, and Datastar's own fetch retry reconnects with no code.
  # (`timeout` is coreutils, from the agnostic base image, not the customerenv layer.)
  #
  # Each connection therefore re-tails the backlog, so clear the panel first: without it a
  # reconnect appends a second copy of the last $LOG_TAIL lines, with ids that collide.
  ^timeout $"($LOG_WINDOW)" journalctl -u $"site@($label)" -o json -n $LOG_TAIL -f
  | lines
  | enumerate
  | each {|it|
      let e = ($it.item | from json)
      let ts = (try { ($e.__REALTIME_TIMESTAMP | into int) * 1000 | into datetime | format date "%H:%M:%S" } catch { "" })
      # MESSAGE comes back as a byte list when the line isn't valid UTF-8; show it either way
      let msg = (if ($e.MESSAGE? | describe) == "string" { $e.MESSAGE } else { $e.MESSAGE? | default "" | to json -r })
      let row = (LI {id: $"log-($it.index)" class: "logline"} (SPAN {class: "ts"} $ts) (SPAN {class: "msg"} $msg)
        | to datastar-patch-elements --selector "#loglines" --mode append)
      # bounded panel: drop the row that just fell out of the window
      if $it.index >= $LOG_CAP {
        [$row ("" | to datastar-patch-elements --selector $"#log-($it.index - $LOG_CAP)" --mode remove)]
      } else {
        [$row]
      }
    }
  | flatten
  # `prepend`, not a leading list: it keeps the pipeline lazy, and the rows still stream
  | prepend ("" | to datastar-patch-elements --selector "#loglines" --mode inner)
  | to sse
}

def do-restart [label: string] {
  let r = (^systemctl restart $"site@($label)" | complete)
  if $r.exit_code != 0 { resp $"restart failed: ($r.stderr)" 500 {} } else { resp "" 302 {Location: $"/s/($label)"} }
}

{|req|
  let body = $in
  if ($req.path | str starts-with "/assets/") {
    serve-file $ASSETS "/assets/" $req.path ""
  } else {
    let cfg = (load-cfg)
    if ($cfg | is-empty) {
      "admin not configured" | metadata set { merge {'http.response': {status: 503}} }
    } else {
      let ss = (make-file-store $"($AUTH_DIR)/sessions")
      let sess = (load-session $req $ss)
      # gated areas that aren't a single fixed path: the gallery and per-site pages
      if ($req.path | str starts-with "/screenshots") {
        if ($sess | is-empty) { resp "" 302 {Location: "/"} } else if ($req.path == "/screenshots") { screenshots-page (who-of $sess) $cfg } else { serve-file $SHOTS "/screenshots/" $req.path "image/png" }
      } else if ($req.path | str starts-with "/s/") {
        if ($sess | is-empty) { resp "" 302 {Location: "/"} } else {
          let parts = ($req.path | str replace --regex '^/s/' '' | split row '/' | where {|p| $p != ""})
          let label = ($parts | get -o 0 | default "")
          if not (valid-label $label) { resp "bad label" 400 {} } else {
            match ($parts | skip 1) {
              [] => { site-page $label (who-of $sess) $cfg "detail" }
              ["logs"] => { site-page $label (who-of $sess) $cfg "logs" }
              ["logs" "stream"] => { logs-stream $label }
              _ => { resp "not found" 404 {} }
            }
          }
        }
      } else {
        match $req.path {
          "/auth/login" => {
            let nonce = (random uuid)
            resp "" 302 {Location: $"($cfg.broker)/login?tenant=($cfg.tenant)&nonce=($nonce)", "Set-Cookie": $"authnonce=($nonce); Path=/; HttpOnly; Secure; SameSite=Lax"}
          }
          "/auth/accept" => {
            let nonce = (cookie $req "authnonce")
            let payload = (verify-token ($req.query.token? | default "") $cfg)
            if ($payload | is-empty) {
              resp "invalid token" 403 {}
            } else if (($payload.jti? | default "-") != $nonce) {
              resp "nonce mismatch (replay?)" 403 {}
            } else if not (is-allowed "discord" {id: $payload.sub} $cfg.allowlist) {
              resp $"($payload.sub) is not on the allowlist" 403 {}
            } else {
              let hash = ({sub: $payload.sub, username: ($payload.name? | default "")} | to json | do $ss.set)
              resp "" 302 {Location: "/", "Set-Cookie": [$"session=($hash); Path=/; HttpOnly; Secure; SameSite=Lax" "authnonce=; Path=/; Max-Age=0"]}
            }
          }
          "/docs" => { docs-page (who-of $sess) $cfg }
          "/auth/logout" => {
            let hash = (cookie $req "session")
            if ($hash | is-not-empty) { do $ss.delete $hash }
            resp "" 302 {Location: "/", "Set-Cookie": "session=; Path=/; Max-Age=0"}
          }
          "/create" => {
            if ($sess | is-empty) { resp "unauthorized" 401 {} } else if ($req.method != "POST") { resp "method not allowed" 405 {} } else {
              let label = ((parse-form $body).label? | default "" | str trim)
              if not (valid-label $label) { resp "invalid label, use a-z 0-9 - (<=32), not a reserved name" 400 {} } else { do-create $label (load-registry) $cfg.tenant }
            }
          }
          "/restart" => {
            if ($sess | is-empty) { resp "unauthorized" 401 {} } else if ($req.method != "POST") { resp "method not allowed" 405 {} } else {
              let label = ((parse-form $body).label? | default "" | str trim)
              if not (valid-label $label) { resp "invalid label" 400 {} } else { do-restart $label }
            }
          }
          _ => {
            if ($sess | is-empty) { login-page "" $cfg.tenant } else { admin-page (who-of $sess) $cfg (load-registry) }
          }
        }
      }
    }
  }
}
