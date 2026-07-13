# cross-stream-admin

The tenant admin app for [customerenv](https://cross.stream) — served at
`admin.<tenant>.cross.stream`. A tenant logs in and manages their sites: point a **label** at
a public git repo, press deploy, and it's live at `<label>.<tenant>.cross.stream`.

Public on purpose: it holds **no secrets** (see below), and the admin app deploys itself
through the same public-git path it offers tenants — it's just another site.

## What it does

- **Login** — no OAuth secret here. It bounces to the identity broker
  (`auth.cross.stream`), which does the Discord dance and returns a short-lived **signed
  token** (EdDSA, verified with `step` against the broker's public key). The app checks the
  token's `sub` (the user's Discord ID) against a per-VM **allowlist**, then sets its own
  session. One Discord app for all tenants; each tenant VM holds only a public key + a list.
- **Deploy** — associate a label with a public git URL, `git clone` it, check for a `serve.nu`
  at the repo root, and start `site@<label>`. Live immediately at `<label>.<tenant>.cross.stream`.
- **Redeploy** — `git pull` + `systemctl restart site@<label>`.

**Label ≠ repo name.** The label is chosen independently of the repo:
`github.com/cablehead/my-blog-datastar` + label `blog` → `blog.<tenant>.cross.stream`.

## Layout

```
serve.nu               # the app (http-nu handler)
oauth/                 # shared OAuth lib (challenge/CSRF, providers) — dormant here; the
                       #   tenant verifies broker tokens, it does not talk to Discord itself
deploy/
  admin.service        # how the app runs (root, so it can git + systemctl)
  site@.service        # the per-site template the app manages (DynamicUser-sandboxed)
tenant.json.example    # copy to tenant.json per VM (see below)
```

## The site contract

A tenant repo must have a **`serve.nu`** at its root — an
[http-nu](https://github.com/cablehead/http-nu) handler. It runs as
`site@<label>` on `/run/sites/<label>.sock`; the guest Caddy dispatcher routes
`<label>.<tenant>.cross.stream` → that socket by subdomain (one dynamic rule, no per-site
config). Per-site `env` and a redeploy-surviving `state/` live beside `repo/` under
`/srv/sites/<label>/`.

## Instance state (never committed — `.gitignore`d)

Per-VM, materialized at provision/boot, not part of the source:

- `tenant.json` — `{tenant, broker, allowlist}`. The allowlist (Discord user IDs) is this
  VM's gate. Non-secret by design, but per-VM config. Copy from `tenant.json.example`.
- `broker-pub.jwk` — the broker's public verify key; fetch from `<broker>/pubkey`.
- `auth/` — live sessions + CSRF challenges (runtime).

The one OAuth secret lives only on the broker, never here.
