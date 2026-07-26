# Site guide

Everything a site needs to know, in one place. Rendered in the admin at `/docs`.

## The contract

A site is a git repo with a **`serve.nu`** at its root, an
[http-nu](https://github.com/cablehead/http-nu) handler. Push it and it's live at
`<label>.<tenant>.cross.stream`. Each push redeploys.

If you're comfortable with http-nu already, the patterns you'd use in any other project apply
here unchanged. The rest of this page is the small set of things that are specific to us.

## Features

Everything is off by default. A repo opts in with a **`cross-stream.nuon`** at its root:

```
{ store: true, services: true, datastar: true }
```

Those three booleans are the whole vocabulary:

| key | effect |
|-----|--------|
| `store` | the embedded event store (`.cat`, `.append`, `.cas`), at `$HTTP_NU.store` |
| `services` | actors, services, and actions. Implies `store` |
| `datastar` | serves the Datastar JS bundle at `$DATASTAR_JS_PATH` |

You declare intent, not flags. Unknown keys and malformed nuon are rejected when you push, with
the reason printed in your `git push` output.

## Files

Your handler runs from the checked-out tree, sandboxed. Two rules cover nearly everything:

- **The repo directory is disposable.** Every push deletes it and re-extracts it from the pushed
  commit. Anything not in the commit is gone. `.gitignore` does **not** protect a file here, it
  only keeps it out of the commit, which is precisely what gets it deleted. Never keep data you
  care about next to your code.
- **`state/` is yours.** Always there, writable, untouched by deploys. Its path is
  `$env.SITE_STATE`.

| path | lifetime |
|------|----------|
| repo | rebuilt on every push |
| `$env.SITE_STATE` | persists across pushes and restarts; removed only when the site is deleted |
| `$HTTP_NU.store` | same, when `store` is enabled |

Everything else is read-only, so `state/` (and the store, if enabled) are the only durable places
to write. `/tmp` works for scratch but is shared with the rest of the VM and does not survive a
reboot. Your site's account is not stable between restarts, so key off these paths and never off
file ownership.

### SQLite

Works, including WAL mode. Keep the database directly in `$env.SITE_STATE` so its `-wal` and
`-shm` siblings can be created beside it:

```nushell
let db = ($env.SITE_STATE | path join "app.db")
```

Do not put it in the repo and `.gitignore` it. That is the one arrangement guaranteed to lose
your data on the next push.

## Platform

You cannot install packages. To use a tool we don't ship, **commit a static binary to your
repo** and call it from your handler. The executable bit is preserved by the deploy (`git
update-index --chmod=+x` if you need to set it).

Build for **Ubuntu 24.04 LTS, x86_64, glibc 2.39**:

| toolchain | target |
|-----------|--------|
| Rust | `x86_64-unknown-linux-musl` (fully static, safest) or `x86_64-unknown-linux-gnu` |
| Go | `GOOS=linux GOARCH=amd64 CGO_ENABLED=0` |
| Zig / C | `-target x86_64-linux-musl`, statically linked |

Already on `PATH`: `nu`, `http-nu`, `git`, `caddy`, `bat`, and `step`. For crypto beyond
nushell's `hash sha256` / `hash md5` builtins, reach for `step` first; it covers key generation,
JWT, and JWE without you shipping anything.
