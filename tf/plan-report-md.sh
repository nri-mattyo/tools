#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_DEFAULT_PROFILE="${AWS_DEFAULT_PROFILE:-NRI_prod}"

# Markdown variant of plan-report.sh, intended for pasting into a PR
# description/comment or reading in any Markdown viewer.
#
# Each resource becomes a collapsible <details> block whose body is a ```diff
# fence: GitHub renders `-` (old) lines red and `+` (new) lines green, which
# gives the old->new contrast for free. Leaves that force a replacement are
# flagged with a trailing `# forces replacement` comment.
#
# No ANSI color here (Markdown handles presentation), so this is safe to redirect:
#   ./plan-report-md.sh */.terraform/*.tfplan.json > plan.md
jq -r '
    # ---- deep-diff helpers (shared with baseline) ---------------------------
    def decode_deep:
      if   type == "object" then map_values(decode_deep)
      elif type == "array"  then map(decode_deep)
      elif type == "string" then
            (try fromjson catch null) as $p
            | if ($p|type) == "object" or ($p|type) == "array"
              then ($p | decode_deep) else . end
      else . end;

    def keyify_named:
      if type == "object" then map_values(keyify_named)
      elif type == "array" then
        ( if (length > 0)
             and all(.[]; type == "object" and has("name"))
             and ((map(.name) | length) == (map(.name) | unique | length))
          then (map({ key: (.name|tostring), value: keyify_named }) | from_entries)
          else map(keyify_named) end )
      else . end;

    def fmtpath:
      reduce .[] as $k (null;
        if   . == null             then ($k|tostring)
        elif ($k|type) == "number" then "\(.)[\($k)]"
        else "\(.).\($k)" end);

    # Tolerant getpath: keyify_named can make before/after/after_unknown differ
    # in shape (array on one side, name-keyed object on another), so a path
    # valid on one side may try to index an array with a string on another.
    # Return null instead of aborting the whole file.
    def get_safe($v; $p): (try ($v | getpath($p)) catch null);

    def unknown_at($au; $p):
      any(range(0; ($p|length)+1) as $i | get_safe($au; $p[:$i]); . == true);

    def diff_entries:
      (.change.replace_paths // [])                         as $rp
      | (.change.before        | decode_deep | keyify_named) as $b
      | (.change.after         | decode_deep | keyify_named) as $a
      | (.change.after_unknown // {})                        as $au
      | ( [ $b | paths(scalars) ] + [ $a | paths(scalars) ] | unique ) as $paths
      | [ $paths[]
          | . as $p
          | { p: $p,
              before: get_safe($b; $p),
              after:  (if unknown_at($au; $p) then "(known after apply)"
                       else get_safe($a; $p) end),
              forces: (any($rp[]; . as $pre | $p[:($pre|length)] == $pre)) }
          | select(.before != .after) ];

    # ---- markdown rendering -------------------------------------------------
    # action -> "<emoji> <label>"
    def badge:
      if   . == ["create"]          then "🟢 create"
      elif . == ["delete"]          then "🔴 delete"
      elif . == ["delete","create"] then "♻️ replace"
      elif . == ["create","delete"] then "♻️ replace (create-before-destroy)"
      elif . == ["update"]          then "🟡 update"
      elif . == ["read"]            then "🔵 read"
      else (join("/")) end;

    # One resource -> a ```diff body: a `-`/`+` pair per changed leaf.
    def diff_block:
      [ diff_entries[]
        | (.p | fmtpath) as $path
        | (if .before != null then "- \($path) = \(.before|tojson)" else empty end),
          (if .after  != null
           then "+ \($path) = \(.after|tojson)\(if .forces then "   # forces replacement" else "" end)"
           else empty end)
      ];


    # ---- filter -------------------------------------------------------------
#    select(
#        [.resource_changes[]? | select(.change.actions[0] != "no-op")] | length > 0
#    ) |
#    select(input_filename | test("/wpp-\\w+.tfplan.json|/pwc-pepsi.tfplan.json") | not) |
    select(
        [.resource_changes[]?
         | select(.previous_address != null
                  or .change.importing != null
                  or .change.actions[0] != "no-op")] | length > 0
    ) |

    # ---- report (one input document = one customer plan) --------------------
    # Same buckets as plan-report.sh: "removed" = a forget (dropped from state
    # WITHOUT destroying); imports ride alongside a no-op/update via
    # .change.importing; moves are address changes only.
    (input_filename | split("/")[-3]) as $title          # the <customer> dir
    | ( [ .resource_changes[]?
          | select(.previous_address != null
                   or .change.importing != null
                   or .change.actions[0] != "no-op") ] ) as $int
    | ($int | map(select(.change.actions[0] != "no-op"
                         and .change.actions != ["forget"]))) as $changes
    | ($int | map(select(.change.actions == ["forget"])))     as $removed
    | ($int | map(select(.change.importing != null)))         as $imports
    | ($int | map(select(.previous_address != null)))         as $moves
    | ( [ "## \($title)",
          "",
          ( [ (if ($changes|length) > 0 then "\($changes|length) change(s)" else null end),
              (if ($imports|length) > 0 then "\($imports|length) import(s)" else null end),
              (if ($removed|length) > 0 then "\($removed|length) removed"   else null end),
              (if ($moves|length)   > 0 then "\($moves|length) move(s)"     else null end) ]
            | map(select(. != null)) | "_\(join(", "))_" ),
          "" ]
        + ( $changes
            | sort_by("\(.change.actions|join("/")) \(.address)")
            | map(
                . as $rc
                | ($rc.change.actions | badge) as $b
                | ($rc | diff_block) as $lines
                | [ "<details>",
                    "<summary>\($b) — <code>\($rc.address)</code></summary>",
                    "" ]
                  + (if ($lines|length) > 0
                     then ["```diff"] + $lines + ["```"]
                     else ["_no attribute-level diff (metadata only)_"] end)
                  + [ "", "</details>", "" ] )
            | add // [] )
        + ( if ($imports|length) > 0
            then [ "<details>",
                   "<summary>📥 \($imports|length) imported (adopted into state)</summary>",
                   "", "```" ]
                 + ( $imports | sort_by(.address)
                     | map("\(.address)  (id: \(.change.importing.id // "?"))") )
                 + ["```", "", "</details>", "" ]
            else [] end )
        + ( if ($removed|length) > 0
            then [ "<details>",
                   "<summary>🗑️ \($removed|length) removed from state (not destroyed)</summary>",
                   "", "```" ]
                 + ( $removed | sort_by(.address) | map(.address) )
                 + ["```", "", "</details>", "" ]
            else [] end )
        + ( if ($moves|length) > 0
            then [ "<details>",
                   "<summary>↪️ \($moves|length) moved (address change only)</summary>",
                   "", "```" ]
                 + ( $moves | sort_by(.address)
                     | map("\(.previous_address)\n  => \(.address)") )
                 + ["```", "", "</details>", "" ]
            else [] end )
        + [ "", "---", "" ]
      )
    | join("\n")
    ' \
    "$@"
