# admin.<tenant> — broker-verified login + site deploys. Holds NO OAuth secret: only the
# broker's public key + an allowlist. Runs as root (see deploy/admin.service) so it can drive
# git + systemctl; the sites it manages stay DynamicUser-sandboxed (see deploy/site@.service).
use /home/app/admin/oauth/lib.nu *

const CFG = "/home/app/admin/tenant.json"        # {tenant, broker, allowlist}
const BROKER_PUB = "/home/app/admin/broker-pub.jwk"
const AUTH_DIR = "/home/app/admin/auth"
const STEP = "/usr/local/bin/step"
const REGISTRY = "/home/app/admin/registry.nuon" # [{repo, label}] — one label per deployment
const SITES = "/home/app/sites"                  # /home/app/sites/<label>/{repo,env,state}

def verify-token [token: string, cfg: record] {
  let r = ($token | ^$STEP crypto jwt verify --key $BROKER_PUB --iss $cfg.broker --aud $cfg.tenant | complete)
  if $r.exit_code == 0 { $r.stdout | from json | get payload } else { null }
}

def load-cfg [] { if ($CFG | path exists) { open --raw $CFG | from json } else { null } }

def load-registry [] { if ($REGISTRY | path exists) { open $REGISTRY } else { [] } }

def cookie [req: record, name: string] {
  let raw = ($req.headers | get -o cookie | default "")
  if ($raw | is-empty) { "" } else { $raw | parse-cookies | get -o $name | default "" }
}

def resp [body: string, status: int, headers: record] {
  $body | metadata set { merge {'http.response': {status: $status, headers: $headers}} }
}

# Parse an application/x-www-form-urlencoded body into a record.
def parse-form [body: string] {
  if ($body | is-empty) { {} } else {
    $body | split row "&" | reduce --fold {} {|pair, acc|
      let kv = ($pair | split row "=")
      $acc | insert ($kv.0) (($kv.1? | default "") | str replace --all "+" " " | url decode)
    }
  }
}

# A label becomes a subdomain, a socket name, a unit instance, and a dir — so keep it strict:
# lowercase alnum + dash, <=32, and never a reserved slot.
def valid-label [label: string] {
  ($label =~ '^[a-z0-9][a-z0-9-]{0,31}$') and ($label not-in ["admin" "www" "placeholder"])
}

# Only https git URLs. Blocks file://, git's ext::sh (arbitrary command execution), and
# leading-dash option injection. We clone with `--` too, as defence in depth.
def valid-repo [repo: string] { $repo =~ '^https://[A-Za-z0-9._~:/@%-]+$' }

# Load the caller's session record, or null if unauthenticated.
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

def unit-state [unit: string] { try { ^systemctl show -p ActiveState --value $unit | str trim } catch { "unknown" } }

def login-page [reason: string] {
  let page = r#'<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width, initial-scale=1'>
<title>admin — sign in</title><style>:root{color-scheme:light dark}body{font:15px/1.5 system-ui,sans-serif;max-width:30rem;margin:16vh auto;padding:0 1.5rem;text-align:center}a.btn{display:inline-block;margin-top:1rem;padding:.6rem 1.2rem;border:1px solid #8886;border-radius:.5rem;text-decoration:none;color:inherit}.note{opacity:.55;font-size:.9em;margin-top:2rem}</style></head><body>
<h2>customerenv admin</h2><a class=btn href="/auth/login">Sign in with Discord</a><p class=note>{{R}}</p></body></html>'#
  $page | str replace "{{R}}" $reason | metadata set --content-type "text/html"
}

# One <tr> per deployment, with a redeploy button. Interpolated values (repo, label, state)
# never contain literal "(", so string interpolation is safe here.
def deploy-rows [reg: list, tenant: string] {
  if ($reg | is-empty) {
    "<tr><td colspan=4 class=note>no deployments yet — add one below</td></tr>"
  } else {
    $reg | each {|d|
      let state = (unit-state $"site@($d.label)")
      let host = $"($d.label).($tenant).cross.stream"
      $"<tr><td class=note>($d.repo)</td><td><a href=\"https://($host)/\">($d.label)</a></td><td class=($state)>($state)</td><td><form method=post action=/redeploy class=inline><input type=hidden name=label value=\"($d.label)\"><button>redeploy</button></form></td></tr>"
    } | str join "\n"
  }
}

def admin-page [user: record, cfg: record, reg: list] {
  let www_target = (try { ls -l /run/sites/www.sock | get target.0 | path basename } catch { "placeholder.sock" })
  let www_state = (if $www_target == "placeholder.sock" { unit-state "site@placeholder" } else { unit-state $"site@($www_target | str replace '.sock' '')" })
  let admin_state = (unit-state "admin.service")
  let who = ($user.username? | default ($user.sub? | default "?"))
  let rows = (deploy-rows $reg $cfg.tenant)
  let page = r#'<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width, initial-scale=1'>
<title>customerenv admin</title><style>:root{color-scheme:light dark}body{font:15px/1.5 system-ui,sans-serif;max-width:48rem;margin:6vh auto;padding:0 1.5rem}table{border-collapse:collapse;width:100%;margin:1rem 0}td,th{text-align:left;padding:.45rem .7rem;border-bottom:1px solid #8884;vertical-align:top}a{color:inherit}.active{color:#3a3}.failed{color:#c33}.note{opacity:.55;font-size:.9em}.top{display:flex;justify-content:space-between;align-items:baseline}form.inline{margin:0}button{font:inherit;padding:.25rem .7rem;border:1px solid #8886;border-radius:.4rem;background:none;color:inherit;cursor:pointer}.new{margin-top:2rem;padding:1rem 1.2rem;border:1px solid #8884;border-radius:.6rem}.new input{font:inherit;padding:.4rem .5rem;margin:.2rem .4rem;border:1px solid #8886;border-radius:.4rem;background:none;color:inherit}.new label{display:inline-block;min-width:3.5rem;opacity:.7}</style></head><body>
<div class=top><h2>customerenv-{{TENANT}}</h2><span class=note>{{WHO}} · <a href="/auth/logout">sign out</a></span></div>
<table><tr><th>repo</th><th>label</th><th>state</th><th></th></tr>
{{ROWS}}
<tr><td class=note>(builtin placeholder)</td><td><a href="https://www.{{TENANT}}.cross.stream/">www</a></td><td class={{WST}}>{{WST}}</td><td></td></tr>
<tr><td class=note>(builtin)</td><td><a href="https://admin.{{TENANT}}.cross.stream/">admin</a></td><td class={{AST}}>{{AST}}</td><td></td></tr>
</table>
<div class=new><form method=post action=/deploy>
<div><label>repo</label><input name=repo size=42 placeholder="https://github.com/user/repo" required></div>
<div><label>label</label><input name=label size=18 placeholder="blog" pattern="[a-z0-9][a-z0-9-]*" required> <button>deploy</button></div>
</form><p class=note>label &rarr; https://&lt;label&gt;.{{TENANT}}.cross.stream · the repo must have a serve.nu at its root</p></div>
</body></html>'#
  $page
    | str replace --all "{{ROWS}}" $rows
    | str replace --all "{{WHO}}" $who
    | str replace --all "{{WST}}" $www_state
    | str replace --all "{{AST}}" $admin_state
    | str replace --all "{{TENANT}}" $cfg.tenant
    | metadata set --content-type "text/html"
}

# git clone a public repo into a fresh site slot and start it. Returns a response.
def do-deploy [repo: string, label: string, reg: list] {
  let dir = $"($SITES)/($label)"
  if ($label in ($reg | get -o label | default [])) {
    resp $"label ($label) already in use — delete it first" 409 {}
  } else if ($dir | path exists) {
    resp $"($dir) already exists on disk" 409 {}
  } else {
    mkdir $dir
    let clone = (^git clone --depth 1 -- $repo $"($dir)/repo" | complete)
    if $clone.exit_code != 0 {
      ^rm -rf -- $dir
      resp $"git clone failed: ($clone.stderr)" 502 {}
    } else if not ($"($dir)/repo/serve.nu" | path exists) {
      ^rm -rf -- $dir
      resp "repo has no serve.nu at its root" 422 {}
    } else {
      $reg | append {repo: $repo, label: $label} | save --force $REGISTRY
      let start = (^systemctl enable --now $"site@($label)" | complete)
      if $start.exit_code != 0 {
        resp $"cloned + registered, but failed to start: ($start.stderr)" 500 {}
      } else {
        resp "" 302 {Location: "/"}
      }
    }
  }
}

# git pull an existing deployment and restart it. Returns a response.
def do-redeploy [label: string] {
  let dir = $"($SITES)/($label)"
  if not ($"($dir)/repo/serve.nu" | path exists) {
    resp $"($label) is not deployed" 404 {}
  } else {
    let pull = (^git -C $"($dir)/repo" pull --ff-only | complete)
    if $pull.exit_code != 0 {
      resp $"git pull failed: ($pull.stderr)" 502 {}
    } else if not ($"($dir)/repo/serve.nu" | path exists) {
      resp "serve.nu vanished after pull" 422 {}
    } else {
      let r = (^systemctl restart $"site@($label)" | complete)
      if $r.exit_code != 0 { resp $"restart failed: ($r.stderr)" 500 {} } else { resp "" 302 {Location: "/"} }
    }
  }
}

{|req|
  let body = $in
  let cfg = (load-cfg)
  if ($cfg | is-empty) {
    "admin not configured" | metadata set { merge {'http.response': {status: 503}} }
  } else {
    let ss = (make-file-store $"($AUTH_DIR)/sessions")
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
      "/deploy" => {
        let s = (load-session $req $ss)
        if ($s | is-empty) {
          resp "unauthorized" 401 {}
        } else if ($req.method != "POST") {
          resp "method not allowed" 405 {}
        } else {
          let form = (parse-form $body)
          let label = ($form.label? | default "" | str trim)
          let repo = ($form.repo? | default "" | str trim)
          if not (valid-label $label) {
            resp "invalid label — use a-z 0-9 - (<=32), not a reserved name" 400 {}
          } else if not (valid-repo $repo) {
            resp "invalid repo — must be an https:// git URL" 400 {}
          } else {
            do-deploy $repo $label (load-registry)
          }
        }
      }
      "/redeploy" => {
        let s = (load-session $req $ss)
        if ($s | is-empty) {
          resp "unauthorized" 401 {}
        } else if ($req.method != "POST") {
          resp "method not allowed" 405 {}
        } else {
          let label = ((parse-form $body).label? | default "" | str trim)
          if not (valid-label $label) { resp "invalid label" 400 {} } else { do-redeploy $label }
        }
      }
      _ => {
        let s = (load-session $req $ss)
        if ($s | is-empty) { login-page "" } else { admin-page $s $cfg (load-registry) }
      }
    }
  }
}
