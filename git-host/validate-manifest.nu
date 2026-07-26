# Validate a cross-stream.nuon manifest passed as $env.CONTENT. Prints a human reason and
# exits 1 if invalid; exits 0 (silent) if fine. Called by the pre-receive hook.
# `from nuon` is data deserialization (not eval), so untrusted content is safe to parse.
let m = (try { $env.CONTENT | from nuon } catch { print "not valid nuon, expected e.g. { store: true }"; exit 1 })
if (($m | describe | str starts-with "record") == false) { print "must be a record, e.g. { store: true }"; exit 1 }
let known = [store services datastar]
let bad = ($m | columns | where {|k| $k not-in $known })
if ($bad | is-not-empty) { print $"unknown key\(s\): ($bad | str join ', '), known keys are store, services, datastar"; exit 1 }
for k in ($m | columns) {
  if (($m | get $k | describe) != "bool") { print $"($k) must be true or false" ; exit 1 }
}
