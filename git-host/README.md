# git-host

The git push-to-deploy gateway for [customerenv](https://cross.stream) tenants. A tenant
`git push`es a repo to `git.<tenant>.cross.stream`; the gateway checks it out and (re)starts the
site.

Lives in this repo, deploys as its own unit. It runs as `app` on the reserved `git` label, while
the admin runs as root; the units draw that boundary, not the repo layout. It shares the
`tokens.json` contract with the admin (the admin writes it, this reads it), which is why the two
belong under one version.

> Merged from the standalone `cablehead/cross-stream-git-host` repo, now archived. Shipping the
> two together means the site contract, the manifest keys, and the token format can only ever
> change in one commit.

## How it fits together

The gateway runs as its own site actor on the reserved `git` label. `git-host.service` serves
`/run/sites/git.sock`, and the guest caddy dispatcher routes `git.<tenant>.cross.stream` there.

`serve.nu` is an [http-nu](https://http-nu.cross.stream) handler that speaks git's smart-HTTP
protocol by gatewaying to `git-http-backend` (CGI). Bare repos live at
`/home/app/git/<label>.git`. Push auth is HTTP Basic: a per-site token (sent as the Basic
username or password) is mapped to its label in `/home/app/git/tokens.json`, and a token may
only push to its own label.

Each bare repo carries two hooks, installed by cross-stream-admin's "create site":

- `pre-receive` validates an optional `cross-stream.nuon` in the pushed tree and rejects a
  garbled one before the ref moves. `validate-manifest.nu` is the checker.
- `post-receive` materializes the pushed tree into `/home/app/sites/<label>/repo` with
  `git archive | tar` (not `git checkout` as root, which would leave root-owned reflog and index
  files and break the next push), translates the manifest into http-nu flags written to the
  site's `env`, ensures `state/` exists, then runs `systemctl enable` + `systemctl restart site@<label>` (enable so it survives a reboot).

### Sharing the hooks instead of copying them

`create site` copies the hooks into each bare repo, so every repo holds a snapshot from the
moment it was created and a hook change never reaches sites that already exist. `core.hooksPath`
fixes that: point each bare repo at this directory and one canonical copy serves them all.
Verified on git 2.43: editing the canonical hook takes effect on the next push, no reinstall.

```nushell
# replaces the two `install -m 0755 ...` lines in the admin's do-create
^git --git-dir $bare config core.hooksPath $HOOKS_DIR
```

**Ordering matters.** The hooks are committed executable here, but the copies currently baked
into the layer are `0644`; `install -m 0755` is what makes them executable on the way in. So the
switch is only safe *after* a layer rebuild that ships them from this repo. Doing it sooner
breaks every push on existing tenants, because `core.hooksPath` makes git ignore
`$GIT_DIR/hooks` entirely and the canonical files would not be executable.

Existing bare repos also need `core.hooksPath` set once each; until then they keep using their
stale copy, which can then be deleted.

## The site contract

A pushed repo needs a `serve.nu` at its root, an http-nu handler. It may also carry a
`cross-stream.nuon` to opt into http-nu features. Everything is off by default:

```
{ store: true, services: true, datastar: true }
```

The hook whitelists these keys and builds the flags itself (`--store <persistent path>`,
`--services`, `--datastar`, where `services` implies `store`). A repo declares intent, never raw
args, so it cannot inject `--expose`, `--tls`, `-c`, or `--plugin`. The store persists at
`/home/app/sites/<label>/store` across redeploys, and is removed only when the site is deleted.

### Writable paths

Only `repo/` is rebuilt on each push (`rm -rf` then re-extract), so nothing a site writes there
survives a deploy, `.gitignore` or not. Two sibling dirs persist, both created by the hook with
ownership the sandboxed site can write through:

- `state/`, created unconditionally, handed to the site as `$env.CROSS_STREAM_SITE_STATE`. The general-purpose
  writable dir. The hook has to create it, since a site cannot make one for itself.
- `store/`, created only when the manifest opts in. http-nu's event store.

The post-extract `chmod -R a+rX` is scoped to `repo/` deliberately: the work-tree is what the
push rebuilt, and it is the only thing whose modes should be normalised. The persistent dirs
manage their own.

## Files

| file | role |
| --- | --- |
| `serve.nu` | the smart-HTTP gateway (runs on `/run/sites/git.sock`) |
| `git-host.service` | systemd unit that runs the gateway as `app` with `SupplementaryGroups=sites` |
| `pre-receive` | rejects a bad `cross-stream.nuon` loudly |
| `post-receive` | checkout, feature flags, restart |
| `validate-manifest.nu` | the `cross-stream.nuon` validator |

## Deploy (customerenv layer)

Bake `serve.nu`, the hooks, and `validate-manifest.nu` to `/home/app/git-host/` (owned `app`),
then install and enable `git-host.service`. Create `/home/app/git/` (owned `app`) for the bare
repos. Add the caddy route, emitted per-tenant by `ce-boot-config`:

```
http://git.<tenant>.cross.stream:80 { reverse_proxy unix//run/sites/git.sock }
```

Requires `git-http-backend` (git package), `nu`, and `http-nu` in the base image, plus
passwordless sudo for `app` (the hooks run `systemctl enable`+`restart site@*` and write under
`/home/app/sites/`). `tokens.json` and the bare repos are per-VM runtime state, not baked.
