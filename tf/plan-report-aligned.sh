#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_DEFAULT_PROFILE="${AWS_DEFAULT_PROFILE:-NRI_prod}"

# Aligned variant of plan-report.sh.
#
# Keeps the flat (greppable) full path, but puts it on its own line and stacks
# the old/new values beneath it so they line up vertically and never run off
# the screen:
#
#   [delete/create] …aws_ecs_task_definition.mcp[0]
#     container_definitions.newton-mcp.environment.MCP_JWKS_URI.value  (forces replacement)
#       - "https://login.newtonresearch.ai/.well-known/jwks.json"
#       + "https://wpp-scj.newtonresearch.ai/oauth/jwks"
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

    # ---- aligned rendering --------------------------------------------------
    # One entry -> a path line + a "- old" line + a "+ new" line (vertically
    # aligned). Null sides (pure add/remove) emit only the relevant marker.
    def aligned_lines:
      [ (diff_entries | sort_by(.p))[]
        | (.p | fmtpath) as $path
        | (if .forces then (" (forces replacement)" | paint("31")) else "" end) as $f
        | ( "    " + $path + $f ),
          (if .before != null then ("      " + ("- " + (.before|tojson) | paint("31"))) else empty end),
          (if .after  != null then ("      " + ("+ " + (.after |tojson) | paint("32"))) else empty end)
      ];

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
                        | ($rc | aligned_lines) as $body
                        | { sort: "\($rc.change.actions|join("/")) \($rc.address)",
                            out: ((("  [\($rc.change.actions|join("/"))] - \($rc.address)")
                                    | paint($rc.change.actions|action_color))
                                  + (if ($body|length) > 0 then "\n" + ($body|join("\n")) else "" end)) }
                    ] | sort_by(.sort) | map(.out) | join("\n"))"
                ) else (null) end,
                if (.moves | length > 0) then "Moves (\(.moves|length)):" else (null) end
            ] | map(select(. != null)) | join("\n")
    ]) | join("\n")
    ' \
    "$@"
