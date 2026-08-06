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
- `post-receive` streams the pushed tree through `git archive` (not `git checkout` as root,
  which would leave root-owned reflog and index files and break the next push) into
  **`ce-site-deploy`**, one privileged call that does all the root work: rebuild
  `/home/app/sites/<label>/repo`, translate the manifest into http-nu flags in the site's `env`,
  ensure `state/` (and `store/` when opted in), then `systemctl enable` + `restart site@<label>`
  (enable so it survives a reboot).

  It is one script because it was nine `sudo` calls, and **every sudo session writes three pam
  lines to the journal** -- so a push logged about thirty lines of session bookkeeping around
  nine lines of work, and `journalctl -u git-host` was unreadable. `ce-site-deploy` re-validates
  the label rather than trusting the caller: it runs as root off a stdin stream.

### Shared hooks, not per-repo copies

`create site` used to copy the hooks into each bare repo, so every repo held a snapshot from the
moment it was created and a hook change never reached sites that already existed. It now sets
`core.hooksPath` to this directory instead, so one canonical copy serves them all and an edit
takes effect on the next push (verified on git 2.43).

The precondition for that switch was a layer that ships the hooks executable, since
`core.hooksPath` makes git ignore `$GIT_DIR/hooks` entirely and non-executable canonical hooks
would break every push. That's satisfied: the layer clones this repo as the admin seed and
ce-boot-config copies it up with `cp -a`, both of which preserve the committed `0755`. Confirmed
on the live layer `customerenv-layer-2026-07-27-githost` (admin `0f827a7`).

**Bare repos created before the switch** still use their own stale copy. Backfill once per repo,
then the copies can be deleted:

```nushell
ls /home/app/git/*.git | each {|r|
  ^git -C $r.name config core.hooksPath /home/app/git-host
  rm -f $"($r.name)/hooks/pre-receive" $"($r.name)/hooks/post-receive"
}
```

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
