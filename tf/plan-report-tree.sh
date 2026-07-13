#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_DEFAULT_PROFILE="${AWS_DEFAULT_PROFILE:-NRI_prod}"

# Tree/YAML variant of plan-report.sh.
#
# Same data extraction as the baseline, but each changed leaf is rendered as a
# nested YAML-like tree (shared path prefixes are printed once), and the
# old/new values go on their own aligned lines so differences are easy to spot:
#
#   container_definitions.
#     newton-mcp.
#       environment.
#         MCP_PUBLIC_BASE_URL.
#           value: "MANAGED_OUT_OF_BAND"
#               => "https://wpp-scj.newtonresearch.ai" (forces replacement)
#
# Colorize only on a TTY; honor NO_COLOR (https://no-color.org).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then color=true; else color=false; fi
jq -rc --argjson color "$color" '
    def paint($code): if $color then "\u001b[\($code)m\(.)\u001b[0m" else . end;
    def action_color:
      if   . == ["create"] then "32"
      elif . == ["delete"] then "31"
      elif . == ["delete","create"] then "31"
      elif . == ["update"] then "33"
      else "35" end;

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

    # Structured diff: one object per changed leaf {p, before, after, forces}.
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

    # ---- tree rendering -----------------------------------------------------
    # Indent helper: jq makes "x"*0 == null, so coalesce to "".
    def pad($n): (("  " * $n) // "");
    # Length of the shared leading run of two path arrays.
    def common_len($a; $b):
      ( first( range(0; ([($a|length),($b|length)]|min)) | select($a[.] != $b[.]) )
        // ([($a|length),($b|length)]|min) );

    # Render structured entries as an indented tree. Path segments that match
    # the previous entry are not re-printed.
    def render_tree($entries):
      ($entries | sort_by(.p))
      | reduce .[] as $e ({prev: [], lines: []};
          ($e.p[:-1])         as $dirs
          | ($e.p[-1]|tostring) as $leaf
          | common_len($dirs; .prev) as $c
          | [ range($c; ($dirs|length)) | (pad(.)) + ($dirs[.]|tostring) + "." ] as $branch
          | (pad($dirs|length))  as $li
          | ($e.before|tojson)   as $bj
          | ($e.after |tojson | paint("32")) as $aj
          | (if $e.forces then (" (forces replacement)" | paint("31")) else "" end) as $f
          | { prev: $dirs,
              lines: ( .lines + $branch
                       + [ $li + $leaf + ": " + $bj,
                           $li + "    => " + $aj + $f ] ) }
        )
      | .lines | map("    " + .);   # nest the whole tree under its resource line

    # ---- report -------------------------------------------------------------
    ["\n","*"*50, "*** \(input_filename | split("/")[-3:]|join("/"))", "*"*50] +
    ([
            [ .resource_changes[]?
              | select(.previous_address != null or .change.actions[0] != "no-op") ]
            | { moves:   [.[] | select(.previous_address != null)],
                changes: [.[] | select(.change.actions[0] != "no-op")] }
            | [
                if (.changes | length > 0) then (
                    "Changes (\(.changes|length)):"
                    + "\n\([
                        .changes[]
                        | . as $rc
                        | (render_tree($rc | diff_entries)) as $tree
                        | { sort: "\($rc.change.actions|join("/")) \($rc.address)",
                            out: ((("  [\($rc.change.actions|join("/"))] - \($rc.address)")
                                    | paint($rc.change.actions|action_color))
                                  + (if ($tree|length) > 0 then "\n" + ($tree|join("\n")) else "" end)) }
                    ] | sort_by(.sort) | map(.out) | join("\n"))"
                ) else (null) end,
                if (.moves | length > 0) then "Moves (\(.moves|length)):" else (null) end
            ] | map(select(. != null)) | join("\n")
    ]) | join("\n")
    ' \
    "$@"
