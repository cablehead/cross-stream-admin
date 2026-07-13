# admin.<tenant> — broker-verified login. Holds NO OAuth secret: only the broker's
# public key + an allowlist. Verifies the broker's signed token, gates on the allowlist.
use /srv/admin/oauth/lib.nu *

const CFG = "/srv/admin/tenant.json"        # {tenant, broker, allowlist}
const BROKER_PUB = "/srv/admin/broker-pub.jwk"
const AUTH_DIR = "/srv/admin/auth"
const STEP = "/usr/local/bin/step"

def load-cfg [] { if ($CFG | path exists) { open --raw $CFG | from json } else { null } }

def cookie [req: record, name: string] {
  let raw = ($req.headers | get -o cookie | default "")
  if ($raw | is-empty) { "" } else { $raw | parse-cookies | get -o $name | default "" }
}

def resp [body: string, status: int, headers: record] {
  $body | metadata set { merge {'http.response': {status: $status, headers: $headers}} }
}

def verify-token [token: string, cfg: record] {
  let r = ($token | ^$STEP crypto jwt verify --key $BROKER_PUB --iss $cfg.broker --aud $cfg.tenant | complete)
  if $r.exit_code == 0 { $r.stdout | from json | get payload } else { null }
}

def unit-state [unit: string] { try { ^systemctl show -p ActiveState --value $unit | str trim } catch { "unknown" } }

def login-page [reason: string] {
  let page = r#'<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width, initial-scale=1'>
<title>admin — sign in</title><style>:root{color-scheme:light dark}body{font:15px/1.5 system-ui,sans-serif;max-width:30rem;margin:16vh auto;padding:0 1.5rem;text-align:center}a.btn{display:inline-block;margin-top:1rem;padding:.6rem 1.2rem;border:1px solid #8886;border-radius:.5rem;text-decoration:none;color:inherit}.note{opacity:.55;font-size:.9em;margin-top:2rem}</style></head><body>
<h2>customerenv admin</h2><a class=btn href="/auth/login">Sign in with Discord</a><p class=note>{{R}}</p></body></html>'#
  $page | str replace "{{R}}" $reason | metadata set --content-type "text/html"
}

def admin-page [user: record] {
  let www_target = (try { ls -l /run/sites/www.sock | get target.0 | path basename } catch { "placeholder.sock" })
  let www_state = (if $www_target == "placeholder.sock" { unit-state "site@placeholder" } else { unit-state $"site@($www_target | str replace '.sock' '')" })
  let www_repo = (if $www_target == "placeholder.sock" { "(placeholder — enter a git url)" } else { $www_target })
  let admin_state = (unit-state "admin.service")
  let who = ($user.username? | default ($user.sub? | default "?"))
  let page = r#'<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width, initial-scale=1'>
<title>customerenv admin</title><style>:root{color-scheme:light dark}body{font:15px/1.5 system-ui,sans-serif;max-width:44rem;margin:8vh auto;padding:0 1.5rem}table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:.4rem .8rem;border-bottom:1px solid #8884}a{color:inherit}.active{color:#3a3}.failed{color:#c33}.note{opacity:.55;font-size:.9em}.top{display:flex;justify-content:space-between;align-items:baseline}</style></head><body>
<div class=top><h2>customerenv-ndyg</h2><span class=note>{{WHO}} · <a href="/auth/logout">sign out</a></span></div>
<table><tr><th>repo</th><th>label</th><th>state</th></tr>
<tr><td class=note>{{WREPO}}</td><td><a href=https://www.ndyg.cross.stream/>www</a></td><td class={{WST}}>{{WST}}</td></tr>
<tr><td class=note>(builtin)</td><td><a href=https://admin.ndyg.cross.stream/>admin</a></td><td class={{AST}}>{{AST}}</td></tr>
</table><p class=note>broker-verified login · read-only — deploy/redeploy land next</p></body></html>'#
  $page | str replace "{{WHO}}" $who | str replace "{{WREPO}}" $www_repo | str replace --all "{{WST}}" $www_state | str replace --all "{{AST}}" $admin_state | metadata set --content-type "text/html"
}

{|req|
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
      _ => {
        let hash = (cookie $req "session")
        let s = (if ($hash | is-empty) { null } else { let v = (do $ss.get $hash); if ($v | is-empty) { null } else { let p = ($v | from json); if ("sub" in ($p | columns)) { $p } else { null } } })
        if ($s | is-empty) { login-page "" } else { admin-page $s }
      }
    }
  }
}
