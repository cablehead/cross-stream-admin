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
const HOOK_SRC = "/home/app/git-host/post-receive"
const ASSETS = "/home/app/admin/assets"
const TPL = "/home/app/admin/templates"
const SHOTS = "/home/app/admin/screenshots"
use /home/app/admin/oauth/lib.nu *

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

# A site's own page: push commands + restart. Also the create-landing (create redirects here).
def site-page [label: string, user: string, cfg: record] {
  let token = (token-for $label)
  if ($token == null) {
    resp $"no such site: ($label)" 404 {}
  } else {
    let remote = $"https://($token)@git.($cfg.tenant).cross.stream/($label).git"
    {
      tenant: $cfg.tenant, user: $user, label: $label
      host: $"($label).($cfg.tenant).cross.stream"
      state: (unit-state $"site@($label)")
      commands: (push-commands $remote)
    } | merge (site-flags $label) | .mj $"($TPL)/site.html"
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
      ^install -m 0755 /home/app/git-host/pre-receive $"($bare)/hooks/pre-receive"
      ^install -m 0755 /home/app/git-host/post-receive $"($bare)/hooks/post-receive"
      ^chown -R app:app $bare
      save-tokens (load-tokens | insert $token $label)
      $reg | append {label: $label, created: (date now | format date "%Y-%m-%d")} | save --force $REGISTRY
      resp "" 302 {Location: $"/s/($label)"}
    }
  }
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
          let label = ($req.path | str replace --regex '^/s/' '' | str replace --all '/' '')
          if (valid-label $label) { site-page $label (who-of $sess) $cfg } else { resp "bad label" 400 {} }
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
