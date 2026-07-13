# Plan report (`plan-report.sh`)

A compact, colorized, **field-level** summary of one or more Terraform plans.
Where `terraform show` hides changed `container_definitions` behind
`(sensitive value)` and collapses everything into a wall of `~`/`+`/`-`, this
report tells you exactly which leaf values changed, which of them *force a
replacement*, and which are *unknown until apply* — across every customer
stack at once.

```
**************************************************
*** us-east-2/experian/.terraform/experian.tfplan.json
**************************************************
Changes (3):
  [create] - …aws_cloudwatch_metric_alarm.mcp_ecs_service_cpu[0]
      alarm_name: null => "newton-mcp-svc-experian-ecs-service-cpu-alarm"
      …
  [delete/create] - …aws_ecs_task_definition.mcp[0]
      container_definitions.newton-mcp.environment.MCP_JWKS_URI.value: "https://login…/jwks.json" => "https://experian…/oauth/jwks" (forces replacement)
      revision: 1 => "(known after apply)"
  [update] - …aws_ecs_service.mcp[0]
      task_definition: "…newton-mcp-experian:1" => "(known after apply)"
Moves (67):
```

## How it fits together

| File | Role |
|------|------|
| `plan.sh` | For each `[a-z]*/` customer dir: `terraform init`, `terraform plan -out …tfplan`, then `terraform show -json …tfplan > …tfplan.json`. Finally calls `plan-report.sh` on the glob of JSON files. |
| `plan-report.sh` | A single `jq` program that reads those `*.tfplan.json` files (passed as `"$@"`) and prints the report. Pure transform — no AWS calls, no Terraform. |

Splitting the report out means you can re-run it over already-generated JSON
without re-planning:

```bash
./plan-report.sh */.terraform/*.tfplan.json          # all stacks
./plan-report.sh experian/.terraform/*.tfplan.json   # one stack
NO_COLOR=1 ./plan-report.sh … > report.txt           # plain text
```

`jq` is invoked with `-r` (raw string output, no JSON quoting) and `-c`
(compact — irrelevant here since the program emits a single joined string per
file). `--argjson color <bool>` injects the color toggle (see
[Color](#color)).

---

## The plan JSON we read from

`terraform show -json <plan>` emits the
[plan representation](https://developer.hashicorp.com/terraform/internals/json-format).
The report only touches `.resource_changes[]`. Each element looks like:

```jsonc
{
  "address":          "module.customer.…aws_ecs_task_definition.mcp[0]",
  "previous_address": "module.customer.…aws_ecs_task_definition.mcp[0]", // present only if moved
  "type":             "aws_ecs_task_definition",
  "change": {
    "actions":        ["delete", "create"],     // see below
    "before":         { … },                    // state today (null on create)
    "after":          { … },                    // desired (null on delete; partial if unknowns)
    "after_unknown":  { "revision": true, … },  // mirror of `after`, true where "known after apply"
    "replace_paths":  [ ["container_definitions"] ] // attribute paths that triggered replacement
  }
}
```

The four fields under `change` are the whole story; everything the report
prints is derived from them.

### `actions` — what kind of change

`actions` is an array. Its shape encodes the operation:

| `actions` | Meaning | Color |
|-----------|---------|-------|
| `["no-op"]` | nothing changed (filtered out) | — |
| `["create"]` | new resource | green (`32`) |
| `["delete"]` | destroy | red (`31`) |
| `["update"]` | in-place update | yellow (`33`) |
| `["delete","create"]` | **replace** — destroy then recreate | red (`31`) |
| `["create","delete"]` | replace, `create_before_destroy` | magenta (`35`, the `else`) |
| `["read"]` | data-source read | magenta (`35`) |

We treat a change as "interesting" when `.change.actions[0] != "no-op"`.

### `before` / `after` — the values

- **`before`** is the resource as it exists in state right now. `null` for a
  create.
- **`after`** is the desired result. `null` for a delete. For updates/replaces
  it holds the new values — **except** for anything Terraform can't know until
  apply, which is *omitted* from `after` and flagged in `after_unknown`.

### `after_unknown` — "(known after apply)"

This is a structural mirror of `after` where every value Terraform cannot
compute at plan time is `true`. Example for the MCP task definition:

```jsonc
"after_unknown": {
  "arn": true,
  "revision": true,
  "id": true,
  "container_definitions": false
}
```

Why does this happen? A value is unknown when it depends on something that
only exists *after* a resource is created/modified:

- `aws_ecs_task_definition.revision` / `arn` / `id` — AWS assigns the revision
  number when the new task-definition revision is registered, so Terraform
  literally cannot print it during plan.
- `aws_ecs_service.task_definition: "…:1" => "(known after apply)"` — the
  service points at the task-def ARN, and since *that* ARN is unknown (the
  task def is being replaced), this reference is unknown too. **Unknowns
  propagate**: one replaced resource turns every downstream reference into
  "known after apply".

The report renders these as the literal string `(known after apply)` instead
of a misleading `=> null`.

### `replace_paths` — why a replacement is forced

For a replace, `replace_paths` lists the **attribute paths** whose change
triggered the destroy/recreate (rather than an in-place update). It is an
array of path arrays:

```jsonc
"replace_paths": [ ["container_definitions"] ]
```

Why would changing an attribute force a replacement? Some attributes are
immutable on the cloud side, so the provider marks them `ForceNew` in its
schema — changing one can't be done in place, only by making a new object:

- `aws_ecs_task_definition` is **entirely immutable**. There is no "update a
  task definition" API; you register a *new revision*. So *any* change to
  `container_definitions` (or `cpu`, `memory`, volumes, …) appears as
  `replace_paths: [["container_definitions"]]` and a `delete/create`. This is
  expected and benign — the service then rolls to the new revision.
- Other common `ForceNew` examples: an EC2 instance's `availability_zone`, an
  RDS instance's `engine`, a security group's `name`.

A change to a non-`ForceNew` attribute (e.g. an alarm threshold) shows up as a
plain `update` with **no** `replace_paths` entry.

The report appends a red `(forces replacement)` tag to exactly the leaves that
fall under a `replace_paths` prefix — so you can instantly separate the
*cause* of a replacement from incidental noise like `ipc_mode: "" => null`
(provider normalization that came along for the ride).

### `previous_address` — moves

When a resource's address changes but the resource itself doesn't (a
`moved {}` block or a module refactor — e.g. nesting everything under
`module.customer_stack`), the change carries a `previous_address` and
`actions: ["no-op"]`. The report counts these separately as **Moves** so they
don't masquerade as real changes.

---

## The jq methods

The program is a sequence of `def`s followed by the report expression. Each
`def` is a small, composable transform.

### `paint($code)` — conditional ANSI color

```jq
def paint($code): if $color then "[\($code)m\(.)[0m" else . end;
```

Wraps the input string in an [ANSI SGR](https://en.wikipedia.org/wiki/ANSI_escape_code#SGR)
sequence (`ESC[<code>m … ESC[0m`) — but only when the `$color` boolean
(injected via `--argjson color`) is true. When false it's the identity
function, so the same program produces clean text for files/pipes.

### `action_color` — map an `actions` array to a color code

```jq
def action_color:
  if   . == ["create"]           then "32"   # green
  elif . == ["delete"]           then "31"   # red
  elif . == ["delete","create"]  then "31"   # red (replace)
  elif . == ["update"]           then "33"   # yellow
  else "35" end;                              # magenta (read, create-before-destroy, …)
```

Input is the `actions` array; output is the numeric SGR code consumed by
`paint`.

### `decode_deep` — expand embedded JSON strings

```jq
def decode_deep:
  if   type == "object" then map_values(decode_deep)
  elif type == "array"  then map(decode_deep)
  elif type == "string" then
        (try fromjson catch null) as $p
        | if ($p|type) == "object" or ($p|type) == "array"
          then ($p | decode_deep) else . end
  else . end;
```

The core problem this solves: several Terraform attributes are **JSON
documents stored as strings** — most importantly
`aws_ecs_task_definition.container_definitions`, but also IAM
`policy`/`assume_role_policy` documents. A naive diff would just report
`container_definitions: "<huge blob>" => "<huge blob>"`.

`decode_deep` walks the whole structure and, for every string, *tries*
`fromjson`. If the string parses to an object or array, it's replaced by the
parsed value (and recursed into, so nested encoded JSON is expanded too);
otherwise the string is left untouched (`try … catch null` makes non-JSON
strings a no-op). After this, `container_definitions` is a real array the diff
can descend into.

### `keyify_named` — make list diffs order-independent

```jq
def keyify_named:
  if type == "object" then map_values(keyify_named)
  elif type == "array" then
    ( if (length > 0)
         and all(.[]; type == "object" and has("name"))
         and ((map(.name) | length) == (map(.name) | unique | length))
      then (map({ key: (.name|tostring), value: keyify_named }) | from_entries)
      else map(keyify_named) end )
  else . end;
```

ECS arrays (`containerDefinitions`, `environment`, `secrets`, `portMappings`)
are **positional** in JSON but **semantically keyed by `name`**. If you insert
one new env var, every later index shifts, and a positional diff screams about
a dozen "changes" that are really one insertion:

```
environment[5].name: "MCP_PUBLIC_BASE_URL" => "MCP_OAUTH_AS_URL"   # not a real change!
environment[6].name: "NEWTON_BASE_URL"     => "MCP_PUBLIC_BASE_URL"
environment[7]:      null                  => {…}
```

`keyify_named` converts any array whose elements are **all objects with a
unique `name`** into an object keyed by that `name`. The guard matters:

- `length > 0` — skip empty arrays.
- `all(.[]; type=="object" and has("name"))` — only `name`-bearing object lists.
- the `unique` length check — only when `name`s are actually unique (so we
  never silently drop duplicates).

After this the same insertion reads cleanly, keyed by identity:

```
container_definitions.newton-mcp.environment.MCP_JWKS_URI.value: "…/jwks.json" => "…/oauth/jwks"
container_definitions.newton-mcp.environment.MCP_OAUTH_AS_URL.name: null => "MCP_OAUTH_AS_URL"
```

> ⚠️ Arrays without a unique `name` (e.g. `command`, `cidr_blocks`) fall back
> to positional diffing, so insertions there can still cascade. That's a
> deliberate trade-off — there's no stable key to use.

### `fmtpath` — render a path array as an accessor

```jq
def fmtpath:
  reduce .[] as $k (null;
    if   . == null             then ($k|tostring)
    elif ($k|type) == "number" then "\(.)[\($k)]"
    else "\(.).\($k)" end);
```

jq paths are arrays like `["container_definitions","newton-mcp","environment","MCP_JWKS_URI","value"]`.
`fmtpath` folds one into a readable string: numeric segments become `[3]`
(array index), string segments become `.key`, and the first segment has no
leading dot. Result: `container_definitions.newton-mcp.environment.MCP_JWKS_URI.value`.

### `unknown_at($au; $p)` — is this leaf "known after apply"?

```jq
def unknown_at($au; $p):
  any(range(0; ($p|length)+1) as $i | $au | getpath($p[:$i]); . == true);
```

Given the `after_unknown` tree (`$au`) and a leaf path (`$p`), returns true if
**any prefix** of the path is `true`. Checking prefixes (not just the exact
leaf) matters because Terraform marks an unknown at the *highest* level it
applies: if a whole attribute is unknown, `after_unknown` holds
`{"container_definitions": true}` rather than expanding `true` to every nested
leaf. `range(0; len+1)` + `getpath($p[:$i])` walks `[]`, `[k0]`, `[k0,k1]`, …
and `any(…; . == true)` short-circuits on the first `true`.

### `field_diff` — the heart of it

```jq
def field_diff:
  (.change.replace_paths // [])                         as $rp
  | (.change.before        | decode_deep | keyify_named) as $b
  | (.change.after         | decode_deep | keyify_named) as $a
  | (.change.after_unknown // {})                        as $au
  | ( [ $b | paths(scalars) ] + [ $a | paths(scalars) ] | unique ) as $paths
  | [ $paths[]
      | . as $p
      | { before: ($b | getpath($p)),
          after:  (if unknown_at($au; $p) then "(known after apply)"
                   else ($a | getpath($p)) end) }
      | select(.before != .after)
      | (if any($rp[]; . as $pre | $p[:($pre|length)] == $pre)
         then (" (forces replacement)" | paint("31")) else "" end) as $f
      | "      \($p|fmtpath): \(.before|tojson) => \(.after|tojson)\($f)"
    ];
```

Step by step:

1. Bind `replace_paths`, the decoded+keyified `before`/`after`, and
   `after_unknown`. The `// []` / `// {}` defaults guard creates/deletes where
   a field is absent.
2. **`paths(scalars)`** enumerates the path to every *leaf* (non-container)
   value. Taking it from both `before` and `after`, concatenating, and
   `unique`-ing yields the union — so added keys (only in `after`) and removed
   keys (only in `before`) are both covered.
3. For each leaf path `$p`, build `{before, after}`:
   - `before = $b | getpath($p)` — `null` if the key is new.
   - `after` = `(known after apply)` if `unknown_at` says so, else
     `$a | getpath($p)` — `null` if the key was removed.
4. **`select(.before != .after)`** keeps only genuine differences.
5. The `replace_paths` check: `$p[:($pre|length)] == $pre` tests whether
   `$pre` is a **prefix** of the leaf path. If any replace path is a prefix,
   the leaf is part of what forced the replacement → append a red
   `(forces replacement)`.
6. Emit a formatted line. `tojson` on the values keeps strings quoted and
   renders `null`/numbers unambiguously.

The result is an **array of strings** (one per changed leaf), which the report
joins with newlines.

---

## Assembling the report

```jq
["\n","*"*50, "*** \(input_filename | split("/")[-3:]|join("/"))", "*"*50] +
([
  [ .resource_changes[] | select(.previous_address != null or .change.actions[0] != "no-op") ]
  | { moves:   [.[] | select(.previous_address != null)],
      changes: [.[] | select(.change.actions[0] != "no-op")] }
  | [
      if (.changes | length > 0) then
        "Changes (\(.changes|length)):"
        + "\n\([
            .changes[]
            | . as $rc
            | ($rc | field_diff) as $fd
            | { sort: "\($rc.change.actions|join("/")) \($rc.address)",
                out:  (("  [\($rc.change.actions|join("/"))] - \($rc.address)")
                         | paint($rc.change.actions|action_color))
                      + (if ($fd|length) > 0 then "\n" + ($fd|join("\n")) else "" end) }
          ] | sort_by(.sort) | map(.out) | join("\n"))"
      else null end,
      if (.moves | length > 0) then "Moves (\(.moves|length)):" else null end
    ]
  | map(select(. != null)) | join("\n")
]) | join("\n")
```

Notes:

- **Header** — `input_filename` is the file jq is currently reading;
  `split("/")[-3:]|join("/")` keeps the last three segments
  (`<customer>/.terraform/<file>.tfplan.json`) so the banner is readable
  regardless of the absolute path passed in.
- **One partition, two buckets** — the interesting changes are filtered once,
  then split into `moves` (have a `previous_address`) and `changes` (non
  no-op). A pure move is a no-op *with* a `previous_address`, so it lands only
  in `moves`.
- **Sort, then paint** — each change is built as `{sort, out}` where `sort` is
  a *plain* `"action address"` key. We `sort_by(.sort)` and only then take the
  painted `.out`. If we sorted the colored strings directly, the leading ANSI
  escape (`ESC[32m` vs `ESC[31m`) would dominate the sort and group lines by
  color instead of by address.
- **`map(select(. != null))`** drops the `Changes`/`Moves` section entirely
  when its bucket is empty.

## Color

Color is decided **once, in bash**, by `plan-report.sh`:

```bash
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then color=true; else color=false; fi
jq -rc --argjson color "$color" '…'
```

- `[ -t 1 ]` — only colorize when **stdout is a terminal**. Redirect to a file
  or pipe and it auto-disables, so logs stay clean.
- `[ -z "${NO_COLOR:-}" ]` — honor the [`NO_COLOR`](https://no-color.org)
  convention; set `NO_COLOR=1` to force plain output even on a TTY.

The boolean crosses into jq via `--argjson` (so it's a real JSON `true`/`false`,
not the string `"true"`), and every styling decision routes through `paint`,
which is a no-op when `$color` is false.

| Code | Color | Used for |
|------|-------|----------|
| `32` | green | `create` |
| `31` | red | `delete`, `delete/create` (replace), `(forces replacement)` tag |
| `33` | yellow | `update` |
| `35` | magenta | everything else (`read`, `create/delete`, …) |

---

## Variants

`plan-report.sh` is the baseline (compact `path: before => after`). Three
alternative renderers share its exact data-extraction core (`decode_deep`,
`keyify_named`, `unknown_at`, the `diff_entries`/`field_diff` logic) but format
the output differently. Pick by use case:

| Script | Output | Best for |
|--------|--------|----------|
| `plan-report.sh` | one `path: old => new` line per leaf, colorized | quick terminal scan (baseline) |
| `plan-report-aligned.sh` | full path on its own line; `- old` / `+ new` stacked and vertically aligned beneath it | long values / spotting exactly what differs without horizontal scroll; still `grep`-able by full path |
| `plan-report-tree.sh` | YAML-style hierarchy — shared path prefixes printed once, `key:` then an indented `=> new` | deeply-nested attributes (`container_definitions.…`); most human-readable |
| `plan-report-md.sh` | Markdown: a collapsible `<details>` per resource wrapping a ```` ```diff ```` fence | pasting into a PR description/comment (GitHub colors `-` red / `+` green) or any Markdown viewer |

All four take the same `*.tfplan.json` arguments and produce one section per
file:

```bash
./plan-report-tree.sh    */.terraform/*.tfplan.json
./plan-report-aligned.sh wpp-scj/.terraform/*.tfplan.json
./plan-report-md.sh      */.terraform/*.tfplan.json > plan.md   # for a PR
```

The three terminal renderers (`.sh` baseline, `-aligned`, `-tree`) honor the
same TTY + `NO_COLOR` color gate. `plan-report-md.sh` emits no ANSI — Markdown
carries the presentation — so it is always safe to redirect to a file.

Same wpp-scj replacement, three ways:

```text
# aligned
    container_definitions.newton-mcp.environment.MCP_JWKS_URI.value (forces replacement)
      - "https://login.newtonresearch.ai/.well-known/jwks.json"
      + "https://wpp-scj.newtonresearch.ai/oauth/jwks"

# tree
    container_definitions.
      newton-mcp.
        environment.
          MCP_JWKS_URI.
            value: "https://login.newtonresearch.ai/.well-known/jwks.json"
                => "https://wpp-scj.newtonresearch.ai/oauth/jwks" (forces replacement)
```

```diff
# md (rendered by GitHub)
- container_definitions.newton-mcp.environment.MCP_JWKS_URI.value = "https://login.newtonresearch.ai/.well-known/jwks.json"
+ container_definitions.newton-mcp.environment.MCP_JWKS_URI.value = "https://wpp-scj.newtonresearch.ai/oauth/jwks"   # forces replacement
```

> Implementation note: in the variants the ANSI escape in `paint` is written as
> the jq unicode escape `\u001b[...m` rather than a raw ESC byte, so the scripts
> stay copy-paste-safe in any editor. The baseline uses a literal ESC byte;
> both are equivalent at runtime.

## Extending it

- **Show the moves' before/after addresses** — uncomment the block under
  `Moves (…)` in `plan-report.sh`.
- **Decode more embedded JSON** — `decode_deep` is already generic; any
  stringified JSON attribute is handled automatically.
- **Key more lists by a different field** — `keyify_named` is hard-coded to
  `name`; generalize it to try `name`, then `key`, then `sid` if you hit lists
  keyed differently (IAM statement `Sid`, for instance).
- **Filter to only replacements** — wrap the `.changes[]` pipe with
  `select(.change.actions == ["delete","create"])` to audit just the
  destructive churn across the fleet.
