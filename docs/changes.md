# Changes

What's new for sites on cross.stream, newest first. The same list is at `/api/changes` as JSON,
for an agent to read: `curl https://admin.<tenant>.cross.stream/api/changes`.

## 2026-11-24: A key can make a site by pushing to it

A key with "Makes a site" ticked on its page (`/k/<id>`) creates a site when it pushes to a label
that doesn't exist yet. git-host makes it the same way "Create site" does, and adds it to the
key's sites. Only the login can tick it.

## 2026-11-23: A key lists its sites and reads their logs

A key belongs to the account, and reaches every site or only the ones ticked on its page. Besides
pushing, it can list the sites it reaches and read their logs, sent as HTTP Basic auth the way
git sends it:

```
curl -u "$KEY:" https://admin.<tenant>.cross.stream/api/sites
curl -u "$KEY:" "https://admin.<tenant>.cross.stream/api/sites/<site>/logs?n=200"
curl -u "$KEY:" "https://admin.<tenant>.cross.stream/api/sites/<site>/logs?follow=1"
```

A log comes back as NDJSON, one `{at, text}` a line, with `data` added when the line is JSON.
`follow=1` keeps streaming new lines as they're written, for up to 15 minutes.

## 2026-11-18: A site can pin its http-nu version

`{ http_nu: "0.19.0" }` in `cross-stream.nuon` runs the site on that version of http-nu, if the
VM carries it, and its stock plugins come from the same version. Without a pin a site runs the
VM's default, which moves only once every site has moved. A pin the VM doesn't carry is refused
when you push, with the versions it does carry.

## 2026-10-30: A site can see its visitor's address

`$req.trusted_ip` is the visitor's IP address, resolved from the two proxies in front of every
site. The log view in the admin shows it as a column. See "The visitor's address" in the site
guide.

## 2026-09-22: A site can load nushell plugins

`plugins` in `cross-stream.nuon` lists the nushell plugins to load: a stock one by name, such as
`"polars"`, or one you commit to your repo, by its path. See "Plugins" in the site guide.
