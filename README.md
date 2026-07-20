# cross-stream-admin

The tenant admin app for [customerenv](https://cross.stream), served at
`admin.<tenant>.cross.stream`. A tenant logs in, creates a site, and `git push`es to deploy it
at `<label>.<tenant>.cross.stream`.

Public on purpose. It holds no secrets (see below), and it deploys itself through the same
git-push path it offers tenants.

## What it does

- **Login.** No OAuth secret here. It bounces to the identity broker (`auth.cross.stream`),
  which runs the Discord flow and returns a short-lived EdDSA token, verified with `step`
  against the broker's public key. The app checks the token's `sub` (the user's Discord ID)
  against a per-VM allowlist, then sets its own session. One Discord app serves every tenant;
  each tenant VM holds only a public key and a list.
- **Create site.** Pick a label. The app mints a per-site push token, creates a bare repo at
  `/home/app/git/<label>.git` with the deploy hooks, and hands back the exact `git remote add`
  and `git push` lines.
- **Push to deploy.** The tenant pushes to `git.<tenant>.cross.stream/<label>.git`. The
  [git-host](https://github.com/cablehead/cross-stream-git-host) gateway checks the tree out
  into `/home/app/sites/<label>/repo` and restarts `site@<label>`. Each push redeploys.
- **Per-site page** (`/s/<label>`). Shows the push commands, the unit state, a restart button,
  and which http-nu features the site opted into (see the site contract).

The label is chosen independently of any repo. It becomes the subdomain, the socket name, the
systemd instance, and the site directory.

## Layout

```
serve.nu               # the app (an http-nu handler)
templates/             # minijinja pages (base, login, dashboard, site, screenshots)
assets/                # Stellar tokens (stellar.css) + base.css + admin.css + fonts
oauth/                 # shared OAuth lib (challenge/CSRF, providers). Dormant here: the
                       #   tenant verifies broker tokens, it does not talk to Discord itself
deploy/
  admin.service        # how the app runs (root, so it can drive git + systemctl)
  site@.service        # the per-site template the app manages (DynamicUser-sandboxed)
tenant.json.example    # copy to tenant.json per VM (see below)
```

## The site contract

A tenant repo must have a `serve.nu` at its root, an
[http-nu](https://github.com/cablehead/http-nu) handler. It runs as `site@<label>` on
`/run/sites/<label>.sock`, and the guest caddy dispatcher routes
`<label>.<tenant>.cross.stream` to that socket by subdomain (one dynamic rule, no per-site
config). Per-site `env` and a redeploy-surviving `store/` live beside `repo/` under
`/home/app/sites/<label>/`.

A repo may also carry a `cross-stream.nuon` manifest to opt into http-nu features. Everything is
off by default:

```
{ store: true, services: true, datastar: true }
```

`store` enables the embedded event store, `services` enables actors/services/actions (and
implies `store`), and `datastar` serves the Datastar bundle. The git-host hook whitelists these
keys and builds the flags, so a repo declares intent, not raw args. A garbled manifest is
rejected at push time.

## Instance state (never committed, `.gitignore`d)

Per-VM, materialized at provision or boot, not part of the source:

- `tenant.json`: `{tenant, broker, allowlist}`. The allowlist (Discord user IDs) is this VM's
  gate. Non-secret by design, but per-VM config. Copy from `tenant.json.example`.
- `broker-pub.jwk`: the broker's public verify key. Fetch from `<broker>/pubkey`.
- `registry.nuon`: the per-VM list of deployed labels. The app self-seeds it.
- `auth/`: live sessions and CSRF challenges.

The one OAuth secret lives only on the broker, never here.
