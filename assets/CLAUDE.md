# assets — how this app is styled

Three files, in cascade order. `stellar.css` is generated and vendored; the other two are ours.

| file | what it is |
| --- | --- |
| `stellar.css` | Stellar's generated tokens. **Never hand-write a value that belongs here.** |
| `base.css` | raw HTML elements, no classes. Carries ~80% of every page. |
| `admin.css` | this app's own vocabulary. Three classes, listed below. |

Reference: [`understand-stellar`](https://understanding-stellar.cross.stream/) is the live visual
index of every token. Its `lodestar.md` is the styling philosophy this app follows, and its
`glossary.md` defines the token suffixes. Read `lodestar.md` before adding CSS.

## Build it like a box of Lego

From `lodestar.md`:

- **Every value is a token.** No literals. If it's a raw number, a token exists for it.
- **Raw tags are the blocks in the box.** Style `p`, `a`, `h1`–`h6`, `ul`, `table`, `code` once,
  well, with no classes. Reach here first and stay as long as the tags carry the job.
- **A class is a two-hammer decision.** You'd take two hits from a hammer before adding one. A
  class that dresses one element, in one place, named for the spot rather than the thing, is not
  a block — it's a literal with a name. Fold it back into the tags.

## Colour: `-on` and `-dim` belong to their shade

Every shade ships a pair. `--neutral-1-on` is the text for `--neutral-1`; `--neutral-1-dim` is
the *quieter* text for that same surface. **They are only correct on the shade they are named
for.** Text on the page (`--neutral-1`) takes the `-1` pair; text on `kbd`/`th` (`--neutral-3`)
takes `--neutral-3-on`; text on an input (`--neutral-2`) takes `--neutral-2-on`.

**Never reach for a bare ramp step to get "a quieter grey."** `--neutral-7` as a foreground is
choosing a colour by eye, which is exactly what the pair exists to prevent. A bare shade is a
surface, a border, or an accent — never a dim.

The one sanctioned bare-shade foreground is an **accent**: a hue picked off a ramp to sit on the
page, the way a link does. `--primary-7` / `--tertiary-7` / `--error-7` on the log's status column
are accents. There is no pair for "primary text on a neutral surface", so this is the gap the
pattern fills. An accent is not a dim.

**Accents all sit at step 7.** One step across every accent means the hue says which class of
thing it is and nothing else. Escalation is carried by weight — normal, semi-bold, bold — which
is a scale that is actually ordered, where ramp steps are not. If an accent needs to shout,
change its weight, not its step.

If `-dim` reads too faint, the fix is **`dimTargetLc` in the Stellar config and a regenerate**,
never a different token at the call site. See `glossary.md` (`-on`, `-dim`, `dimTargetLc`,
`onTargetLc`, APCA, Lc).

### When to use `-on`, `-dim`, and bold

The pairing rule above says *which* `-on`/`-dim` is legal on a given surface. This says *which
of the two* to pick, and when weight is allowed to join in.

**Colour carries state. Weight carries structure.**

| use | when |
| --- | --- |
| `-on` | what you came to read, and the headings that label it. In a nav: **where you are**. |
| `-dim` | supporting text — captions, notes, counts, timestamps. In a nav: **where you could go**. |
| **bold** | the current item, so state never rests on colour alone. Headings get weight from the tag, not from this rule. |

Applied to the sites index: the `Sites` / `Units` headings are `-on`, the current site is `-on`
+ bold, every other site is `-dim`. The tab row follows the identical rule, plus the underline
it already had. One rule, both navigations, no per-place decision.

Two things this rules out:

- **Don't dim a heading to make it recede.** A heading that shouldn't compete is a smaller or
  quieter *tag*, not a lower-contrast colour. Dimming structure makes the page look broken
  rather than calm.
- **Don't bold something that isn't current.** Bold is not "important", it is "you are here".
  Emphasis inside prose is `<strong>`, which the tag layer already styles.

**Navigation is not the same as a link.** These rules apply to lists of peers you move between
(`aside ul`, `article > nav`), which lose their underline and take state colour. A link in
prose — "all sites & new", a link inside a `<p>` — is an ordinary link: body colour, underline,
no state. Scope nav rules to the list, never to the whole container, or the prose links inside
it get silently conscripted.

### Our stellar.css, and the one edit in it

Generated with a low `dimTargetLc`, so `-dim` came out near Lc 30 — decorative, not readable.
There is **no `stellar.config.json` in this repo** and the `stellar` binary is licence-gated, so
it could not simply be regenerated.

Its `-dim` values were instead transplanted from `understand-stellar`'s build, which targets
`dimTargetLc: 65`. That is sound because **the two builds share an identical base palette** — all
six colour sets, twelve shades, exact match — so the transplant is arithmetically what a
regenerate would have produced. 934 values, `-dim` only; every other token byte-identical.

Do **not** copy that file wholesale. Its dark-mode `--code-*` palette is a *light* syntax theme
(ours is dark), its radius and border-width tokens scale at a different `vw` rate, and it lacks
our `--named-*` ramps.

When a real config appears: set `dimTargetLc: 65`, regenerate, and this note retires.

## The vocabulary

Three classes. Everything else is the tag that already means it.

| class | why it earns one |
| --- | --- |
| `.site` | a sidebar beside a column — layout no tag expresses |
| `.shots` | a responsive image grid — same |
| `.log` | a dense tabular panel; states its own case in a comment |

Reached as tags, not classes: `main > nav` is the page header, `aside` is the sites index,
`article > nav` is the tab row, `figure button[data-copy]` is the copy button. **`aria-current`
carries "you are here"** — no class does, and both navs share one rule for it.

Inside `.log`, the cells are the tags that mean what they hold: `time`, `b`, `code`, `data`,
`small`. A row carries no classes of its own.

## Before you add a class

1. Can a raw tag carry it? Style the tag.
2. Can an existing tag relationship name it (`article > nav`, `main > nav`)? Use that.
3. Is it a state? Use the ARIA attribute (`aria-current`), not a class.
4. Only then, and only if it's layout no tag expresses, add one — on the block's root, styling
   everything inside by descending from it. One class per block, no more.

Adding specificity to beat an existing rule is never the answer. If two rules fight, one of them
is in the wrong file.
