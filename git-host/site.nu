# A site as the admin and git-host both make it: a bare repo with the shared hooks, and a row
# in the registry. The admin makes one from its "create site" form, after a Discord login;
# git-host makes one when a key that can make sites pushes to a site that doesn't exist yet.

export const GIT_ROOT = "/home/app/git"
export const REGISTRY = "/home/app/admin/registry.nuon"
# Canonical location of the deploy hooks: every bare repo's `core.hooksPath` points here, so
# editing a hook takes effect on the next push everywhere. (ce-boot-config symlinks this path at
# the merged layout /home/app/admin/git-host.)
export const HOOKS_DIR = "/home/app/git-host"

export def valid-label [label: string] {
  ($label =~ '^[a-z0-9][a-z0-9-]{0,31}$') and ($label not-in ["admin" "www" "placeholder" "git"])
}

# The registry is app:app 0660, so both the admin (root) and git-host (app) write it.
export def load-registry [] { if ($REGISTRY | path exists) { open $REGISTRY } else { [] } }

# Make the site `label`, recording who made it. Returns null when made, or {status, error}.
export def create-site [label: string, by: string] {
  let reg = (load-registry)
  let bare = $"($GIT_ROOT)/($label).git"
  if not (valid-label $label) {
    {status: 400, error: "invalid label, use a-z 0-9 - (<=32), not a reserved name"}
  } else if ($label in ($reg | get -o label | default [])) {
    {status: 409, error: $"label ($label) already in use, pick another"}
  } else if ($bare | path exists) {
    {status: 409, error: $"($bare) already exists on disk"}
  } else {
    let init = (^git init --bare -b main $bare | complete)
    if $init.exit_code != 0 { {status: 500, error: $"git init failed: ($init.stderr)"} } else {
      ^git -C $bare config http.receivepack true
      ^git -C $bare config http.uploadpack true
      ^git -C $bare config core.hooksPath $HOOKS_DIR
      $reg | append {label: $label, created: (date now | format date "%Y-%m-%d"), by: $by} | save --force $REGISTRY
      null
    }
  }
}
