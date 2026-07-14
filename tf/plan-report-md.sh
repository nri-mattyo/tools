#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_DEFAULT_PROFILE="${AWS_DEFAULT_PROFILE:-NRI_prod}"

# Markdown variant of plan-report.sh, intended for pasting into a PR
# description/comment or reading in any Markdown viewer.
#
# Layout:
#   - Resources are grouped by module as nested <details open> blocks, one
#     level per module, so any level can be collapsed (module levels start
#     open, resource diffs start closed). Summaries carry &nbsp; indentation
#     because GitHub does not indent nested <details> content.
#   - Each resource body is a ```diff fence: `-` (old) and `+` (new) lines
#     render red/green on GitHub. Attribute paths sharing a prefix fold into
#     an indented tree — unmarked header lines ending in "." — and the `=`
#     of leaves at the same level are aligned.
#   - When an old value runs past 40 chars, the new value drops to a
#     continuation line aligned under the value column instead of repeating
#     the attribute name.
#   - Leaves that force a replacement are flagged with a trailing
#     `# forces replacement` comment.
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

    def sp($n): if $n > 0 then (" " * $n) else "" end;

    # summary indentation: GitHub renders nested <details> flush-left, so the
    # visual hierarchy comes from &nbsp; padding in the summary line
    def nb($d): if $d > 0 then ("&nbsp;&nbsp;&nbsp;" * $d) else "" end;

    # diff path components -> display segments; numeric indices attach to the
    # preceding segment ("subnets", 0 -> "subnets[0]")
    def to_segs:
      reduce .[] as $k ([];
        if ($k|type) == "number" then .[:-1] + ["\(.[-1])[\($k)]"]
        else . + [$k|tostring] end);

    # Render [{segs, before, after, forces}] as a tree inside a ```diff fence.
    # Shared prefixes become unmarked (context) header lines ending in ".";
    # leaves at the same node get their `=` aligned. A prefix chain with no
    # branching collapses onto one header line, and a branch holding a single
    # leaf stays flat (full dotted path) instead of opening a header.
    def render_tree($ind):
      def leaf_lines($w; $i):
        (.name + sp($w - (.name|length))) as $n
        | (if .forces then "   # forces replacement" else "" end) as $f
        | (.before|tojson) as $bv
        | (.after |tojson) as $av
        | if   .before == null then ["+ \($i)\($n) = \($av)\($f)"]
          elif .after  == null then ["- \($i)\($n) = \($bv)"]
          elif ($bv|length) > 40
          then ["- \($i)\($n) = \($bv)",
                "+ \($i)\(sp($w + 3))\($av)\($f)"]
          else ["- \($i)\($n) = \($bv)",
                "+ \($i)\($n) = \($av)\($f)"] end;
      ( map(select((.segs|length) > 1)) | group_by(.segs[0]) ) as $groups
      | ( map(select((.segs|length) == 1) | . + {name: .segs[0]})
          + [ $groups[] | select(length == 1)
              | .[0] | . + {name: (.segs | join("."))} ]
          | sort_by(.name) ) as $leaves
      | ( [ $leaves[].name | length ] | max // 0 ) as $w
      | ( [ $leaves[] | leaf_lines($w; $ind) ] | add // [] )
        + ( [ $groups[]
              | select(length > 1)
              | { prefix: .[0].segs[0], entries: map(.segs |= .[1:]) }
              | until( ((all(.entries[]; (.segs|length) > 1))
                        and ((.entries | map(.segs[0]) | unique | length) == 1)) | not;
                       { prefix: "\(.prefix).\(.entries[0].segs[0])",
                         entries: (.entries | map(.segs |= .[1:])) } )
              | [ "  \($ind)\(.prefix)." ]
                + ( .entries | render_tree($ind + "  ") ) ]
            | add // [] );

    def diff_block:
      [ diff_entries[] | . + {segs: (.p | to_segs)} ] | render_tree("");

    # ---- module hierarchy ---------------------------------------------------
    def mod_segs:
      (. // "") | [ scan("module\\.[^.\\[]+(?:\\[[^\\]]*\\])?") ];

    def short_addr:
      (.module_address // "") as $m
      | if $m == "" then .address else .address[(($m|length) + 1):] end;

    def resource_block($d):
      (.change.actions | badge) as $b
      | diff_block as $lines
      | [ "<details>",
          "<summary>\(nb($d))\($b) — <code>\(short_addr)</code></summary>",
          "" ]
        + (if ($lines|length) > 0
           then ["```diff"] + $lines + ["```"]
           else ["_no attribute-level diff (metadata only)_"] end)
        + [ "", "</details>", "" ];

    # [{msegs, rc}] -> nested <details open> per module level; resources that
    # live at the current level render before the sub-modules
    def render_mods($d):
      ( map(select(.msegs == []))
        | sort_by("\(.rc.change.actions|join("/")) \(.rc.address)")
        | [ .[].rc | resource_block($d) ] | add // [] )
      + ( map(select(.msegs != [])) | group_by(.msegs[0])
          | [ .[]
              | .[0].msegs[0] as $name
              | [ "<details open>",
                  "<summary>\(nb($d))📦 <code>\($name)</code></summary>",
                  "" ]
                + ( map(.msegs |= .[1:]) | render_mods($d + 1) )
                + [ "</details>", "" ] ]
          | add // [] );

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
            | map({msegs: (.module_address | mod_segs), rc: .})
            | render_mods(0) )
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
                     | map("   \(.previous_address)\n=> \(.address)") )
                 + ["```", "", "</details>", "" ]
            else [] end )
        + [ "", "---", "" ]
      )
    | join("\n")
    ' \
    "$@"