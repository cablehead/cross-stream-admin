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

def store-hashes [] {
  let r = (^curl -s --unix-socket $SOCK $"http://localhost/?topic=($TOPIC)" | complete)
  if $r.exit_code != 0 { [] } else {
    $r.stdout | lines
      | where {|l| ($l | str trim | is-not-empty) }
      | each {|l| try { ($l | from json).meta?.hash? } catch { null } }
      | where {|h| ($h | is-not-empty) }
  }
}

def main [] {
  if not ($TOKENS | path exists) {
    print "no tokens.json: nothing to migrate"
    return
  }
  let have = (store-hashes)
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
