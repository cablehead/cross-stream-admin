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

# A site's live log, at /s/<label>/logs/stream. The stream IS the state: journalctl is the only
# source, the label is the only parameter, and nothing is shared with any other request -- a
# reconnect just re-reads. Datastar retries the fetch itself, so a dropped connection or a site
# restart self-heals with no code.
#
# Rows are built with the HTML DSL, which escapes plain strings. That matters: a log line
# carries the request path and Host header of whoever hit the site. Never pass one through
# `{__html:}` or `.md`, and never put one in a data-* attribute -- those are Datastar
# expressions, evaluated, so escaping does not cover them. `.highlight` also returns `{__html:}`
# but escapes its input first (checked with a payload carrying `<img onerror=>`), so it is safe
# on log content.
#
# The shapes a site's journal actually holds, counted over 1422 lines across ndyg's five sites:
#
#   http-nu jsonl        request / response / complete  (three per request, ~78% of all lines)
#                        started, stopping, stopped, error
#   systemd              "Started site@x.service - ...", "Stopped ...", "Deactivated
#                        successfully.", "Consumed 13.561s CPU time."
#   raw                  panics and their `note:` trailer

# Gate on a leading `{` rather than just trying `from json`: nushell's parser is lenient enough
# to read `site@cube.service: Deactivated successfully.` as a one-field record, so parsing
# everything would dress systemd's own prose up as structured data.
def log-parse [raw: string] {
  if not ($raw | str starts-with "{") { null } else {
    let v = (try { $raw | from json } catch { null })
    if (($v | describe) | str starts-with "record") { $v } else { null }
  }
}

def log-bytes [n: int] {
  if $n < 1024 { $"($n)B" } else if $n < 1048576 { $"(($n / 1024 * 10 | math round) / 10)k" } else { $"(($n / 1048576 * 10 | math round) / 10)M" }
}

# A payload block, syntax-highlighted. These stack under a row, one per event it has seen.
def log-payload [v: record] { PRE ($v | to json --indent 2 | .highlight json) }

def dsp [selector: string, mode: string] { to datastar-patch-elements --selector $selector --mode $mode }

# `to datastar-patch-elements` takes one string or one {__html} record, so a batch of rows has
# to be joined before it can be sent as a single patch.
def html-join [nodes: list] { {__html: ($nodes | each {|n| $n.__html } | str join "")} }

# One row per request, not three: http-nu emits request -> response -> complete sharing a
# request_id, and they belong on one apache-style line. `res` and `comp` are null while the
# request is still in flight, which is the live case -- the cells render pending and get patched
# when those events arrive. The backlog passes all three at once and renders the row finished.
#
# Correlation is a class, `r-<request_id>`, not an id: the row's id stays the line index, which
# is what the panel cap removes by. A class also sidesteps a CSS problem -- a scru128
# request_id starts with a digit, and `.03gmk...` is not a valid selector.
def row-req [i: int, ts: string, rid: string, req: record, res: any, comp: any] {
  let status = (if $res == null { SPAN {class: "status pending"} "-" } else {
    let st = ($res.status? | default 0)
    SPAN {class: $"status s(($st // 100))"} ($st | into string)
  })
  let size = (if $comp == null { SPAN {class: "size pending"} "-" } else { SPAN {class: "size"} (log-bytes ($comp.bytes? | default 0)) })
  let dur = (if $comp == null { SPAN {class: "dur pending"} "-" } else { SPAN {class: "dur"} $"($comp.duration_ms? | default 0)ms" })
  let payloads = ([$req $res $comp] | where {|v| $v != null } | each {|v| log-payload $v })
  LI {id: $"log-($i)" class: $"logline r-($rid)"} (
    DETAILS
      (SUMMARY
        (SPAN {class: "ts"} $ts)
        (SPAN {class: "verb"} ($req.method? | default "?"))
        (SPAN {class: "path"} ($req.path? | default ""))
        $status $size $dur
        (SPAN {class: "ip"} ($req.trusted_ip? | default "")))
      (DIV {class: "payloads"} $payloads)
  )
}

# Everything that is not a request: lifecycle, error, an http-nu event we do not know, an
# orphaned response whose request fell outside the window, and the systemd / panic lines that
# are not JSON at all. One row, same grid, nothing pending.
def row-note [i: int, ts: string, v: any, raw: string] {
  let kind = (if $v == null { "" } else { $v | get -o message | default "" })
  let text = (match $kind {
    "started" => $"($v.address? | default '') nu ($v.nu_version? | default '?') up in ($v.startup_ms? | default '?')ms"
    "stopping" => $"($v.inflight? | default 0) in flight"
    "stopped" => ""
    "error" => (($v.error? | default "" | lines | where {|l| ($l | str trim) != ""} | get -o 0 | default "") | str trim)
    "response" => $"($v.status? | default '?') in ($v.latency_ms? | default '?')ms, request not in window"
    "complete" => $"(log-bytes ($v.bytes? | default 0)) in ($v.duration_ms? | default '?')ms, request not in window"
    "" => $raw
    _ => ($v | columns | str join " ")
  })
  let tag = (if ($kind | is-empty) { "log" } else { $kind })
  let cls = (match $kind { "error" => "logline note err", "" => "logline note", _ => "logline note life" })
  if $v == null {
    LI {id: $"log-($i)" class: $cls} (SPAN {class: "ts"} $ts) (SPAN {class: "tag"} $tag) (SPAN {class: "note"} $text)
  } else {
    # an error's payload is already a rendered block; as JSON it is one line of escaped \n
    let body = (if $kind == "error" { PRE ($v.error? | default "") } else { log-payload $v })
    LI {id: $"log-($i)" class: $cls} (
      DETAILS
        (SUMMARY (SPAN {class: "ts"} $ts) (SPAN {class: "tag"} $tag) (SPAN {class: "note"} $text))
        (DIV {class: "payloads"} $body)
    )
  }
}

def log-stamp [e: record] {
  try { ($e.__REALTIME_TIMESTAMP | into int) * 1000 | into datetime | format date "%H:%M:%S" } catch { "" }
}

# MESSAGE comes back as a byte list when the line is not valid UTF-8; show it either way.
def log-message [e: record] {
  if ($e.MESSAGE? | describe) == "string" { $e.MESSAGE } else { $e.MESSAGE? | default "" | to json -r }
}

# The backlog is finite, so its requests can be stitched here rather than in the browser: each
# `request` collects the response and complete that share its id, and the two follow-ups are
# then dropped rather than sent as patches of their own.
def backlog-rows [entries: list] {
  let parsed = ($entries | enumerate | each {|it| {
    i: $it.index, ts: (log-stamp $it.item), raw: (log-message $it.item), v: (log-parse (log-message $it.item))
  }})
  let by_rid = ($parsed | where {|p| $p.v != null } | where {|p| ($p.v | get -o request_id) != null })
  let followed = ($by_rid | where {|p| ($p.v | get -o message) in ["response" "complete"] }
    | where {|p| $by_rid | any {|q| ($q.v | get -o message) == "request" and ($q.v.request_id == $p.v.request_id) } }
    | get i)
  $parsed | where {|p| $p.i not-in $followed } | each {|p|
    let rid = (if $p.v == null { null } else { $p.v | get -o request_id })
    if $rid != null and (($p.v | get -o message) == "request") {
      let rest = ($by_rid | where {|q| $q.v.request_id == $rid })
      row-req $p.i $p.ts $rid $p.v ($rest | where {|q| ($q.v | get -o message) == "response" } | get -o 0.v) ($rest | where {|q| ($q.v | get -o message) == "complete" } | get -o 0.v)
    } else {
      row-note $p.i $p.ts $p.v $p.raw
    }
  }
}

# One live journal line in, zero or more patches out. A request opens a row; its response and
# complete fill the pending cells and push their payload under it. If the row is not there --
# the read opened mid-request, or it aged out of the cap -- the selectors match nothing and the
# patches are no-ops.
def live-events [i: int, e: record] {
  let ts = (log-stamp $e)
  let raw = (log-message $e)
  let v = (log-parse $raw)
  let rid = (if $v == null { null } else { $v | get -o request_id })
  let kind = (if $v == null { "" } else { $v | get -o message | default "" })
  if $rid == null or ($kind not-in ["request" "response" "complete"]) {
    [((row-note $i $ts $v $raw) | dsp "#loglines" "prepend")]
  } else if $kind == "request" {
    [((row-req $i $ts $rid $v null null) | dsp "#loglines" "prepend")]
  } else {
    let cells = (if $kind == "response" {
      let st = ($v.status? | default 0)
      [(SPAN {class: $"status s(($st // 100))"} ($st | into string) | dsp $".r-($rid) .status" "outer")]
    } else {
      [
        (SPAN {class: "size"} (log-bytes ($v.bytes? | default 0)) | dsp $".r-($rid) .size" "outer")
        (SPAN {class: "dur"} $"($v.duration_ms? | default 0)ms" | dsp $".r-($rid) .dur" "outer")
      ]
    })
    $cells | append (log-payload $v | dsp $".r-($rid) .payloads" "append")
  }
}

def logs-stream [label: string] {
  # Backlog first, held and sent as ONE patch rather than dribbled out a row at a time. This is
  # the threshold-gate shape from http-nu's examples (examples/quotes/serve.nu) without needing
  # the gate: an xs stream marks the replay/live boundary with an `xs.threshold` frame, and
  # journald has no such marker -- but every entry carries a `__CURSOR`, so reading the backlog
  # to completion and then following `--after-cursor` from its last one draws the boundary
  # exactly, with no gap and no line delivered twice.
  let backlog = (^journalctl -u $"site@($label)" -o json -n $LOG_TAIL --no-pager | complete | get stdout | lines
    | each {|l| try { $l | from json } catch { null } } | where {|e| $e != null })
  let cursor = ($backlog | last | get -o __CURSOR | default "")
  # `inner` both seeds and clears: each read re-renders the backlog, and without replacing the
  # panel a reconnect would show it twice, with colliding ids. Reversed because the panel runs
  # newest first.
  let seed = (html-join (backlog-rows $backlog | reverse) | dsp "#loglines" "inner")

  # `timeout` is load-bearing, not a safety belt. http-nu does not reap the child when the
  # browser goes away: measured on 0.17.2, a bare `journalctl -f` stayed a live child of the
  # server long after the client disconnected, and a heartbeat write did not change that. So
  # every abandoned panel would hold a tail open until the admin restarts. Capping the child's
  # life bounds that to one window, and Datastar's own retry reconnects.
  # (`timeout` is coreutils, from the agnostic base image, not the customerenv layer.)
  let base = ($backlog | length)
  (^timeout $"($LOG_WINDOW)" journalctl -u $"site@($label)" -o json -f --after-cursor $cursor
  | lines
  | enumerate
  | each {|it|
      let e = (try { $it.item | from json } catch { null })
      if $e == null { [] } else {
        let i = ($base + $it.index)
        let evs = (live-events $i $e)
        # bounded panel: drop whatever row line i-$LOG_CAP created, if it created one
        if $i >= $LOG_CAP { $evs | append ("" | dsp $"#log-($i - $LOG_CAP)" "remove") } else { $evs }
      }
    }
  | flatten
  # `prepend`, not a leading list: it keeps the tail lazy. A list literal would not parse here,
  # and `let` on the follow stream would try to collect it forever.
  | prepend $seed) | to sse
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
