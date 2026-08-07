# One-shot: fold the legacy plaintext tokens.json into git-host's key store.
#
# The old map was keyed BY the secret -- { "<token>": "<label>" } -- which is what makes this
# migration lossless and invisible to customers: every hash can be computed from the file we
# already have, so the key a tenant is holding keeps working and nobody updates a remote.
#
# Idempotent: a token whose hash is already in the store is skipped, so running it twice, or
# on every deploy, adds nothing.
#
# Run as app (it only needs the store socket), on the tenant:
#   nu /home/app/admin/git-host/migrate-tokens.nu

const TOKENS = "/home/app/git/tokens.json"
const SOCK = "/home/app/git/store/sock"
const TOPIC = "site.token"

# Returns null if the store could not be read. That distinction is the whole point: an
# unreadable store must NOT look like an empty one. It did once, and the cost was every key
# on the tenant appended a second time -- the socket file survives a git-host restart, so a
# `[ -S sock ]` check passed against a stale socket before the new process had bound, the
# read failed, and "no hashes found" was taken to mean "nothing migrated yet".
def store-hashes [] {
  let r = (^curl -s --fail --unix-socket $SOCK $"http://localhost/?topic=($TOPIC)" | complete)
  if $r.exit_code != 0 { null } else {
    $r.stdout | lines
      | where {|l| ($l | str trim | is-not-empty) }
      | each {|l| try { ($l | from json).meta?.hash? } catch { null } }
      | where {|h| ($h | is-not-empty) }
  }
}

# Wait for the store to answer, not for its socket file to exist.
def wait-for-store [] {
  mut ok = false
  for _ in 1..30 {
    if (^curl -s --fail --max-time 2 --unix-socket $SOCK "http://localhost/?limit=1" | complete).exit_code == 0 {
      $ok = true
      break
    }
    sleep 1sec
  }
  $ok
}

def main [] {
  if not ($TOKENS | path exists) {
    print "no tokens.json: nothing to migrate"
    return
  }
  if not (wait-for-store) {
    error make {msg: $"key store did not answer on ($SOCK); refusing to migrate"}
  }
  let have = (store-hashes)
  if $have == null {
    error make {msg: "could not read the key store; refusing to migrate (an unreadable store is not an empty one)"}
  }
  let toks = (open --raw $TOKENS | from json)
  let rows = ($toks | transpose secret label)
  mut added = 0
  for e in $rows {
    let h = ($e.secret | hash sha256)
    if not ($h in $have) {
      let meta = ({
        label: $e.label
        # named for where it came from, so a tenant can see which key predates the change
        name: "migrated"
        hash: $h
        suffix: ($e.secret | str substring (-6..))
        created: (date now | format date "%Y-%m-%d")
      } | to json --raw | encode base64)
      let r = (^curl -s --unix-socket $SOCK -X POST --data "" -H $"xs-meta: ($meta)"
        $"http://localhost/append/($TOPIC)?ttl=forever" | complete)
      if $r.exit_code == 0 { $added = $added + 1 }
    }
  }
  print $"migrated ($added) of ($rows | length) key\(s\)"
}
