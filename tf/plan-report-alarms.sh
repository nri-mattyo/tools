#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_DEFAULT_PROFILE="${AWS_DEFAULT_PROFILE:-NRI_prod}"

# loop through all of the jobs and highlight the changes.
# Colorize only when stdout is a terminal (so tee'"'"'d logs stay clean), and
# honor the NO_COLOR convention (https://no-color.org).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then color=true; else color=false; fi
jq -rc --argjson color "$color" '
    # ---- color helpers ------------------------------------------------------
    # Wrap a string in an ANSI SGR code, but only when --argjson color is true.
    def paint($code): if $color then "[\($code)m\(.)[0m" else . end;
    # green=create, red=delete, yellow=update, magenta=replace/other.
    def action_color:
      if   . == ["create"] then "32"
      elif . == ["delete"] then "31"
      elif . == ["delete","create"] then "31"
      elif . == ["update"] then "33"
      else "35" end;

    # ---- deep-diff helpers --------------------------------------------------

    # Recursively decode embedded JSON strings (container_definitions, IAM
    # policy docs, etc.) so the diff descends into real structure instead of
    # comparing two opaque blobs.
    def decode_deep:
      if   type == "object" then map_values(decode_deep)
      elif type == "array"  then map(decode_deep)
      elif type == "string" then
            (try fromjson catch null) as $p
            | if ($p|type) == "object" or ($p|type) == "array"
              then ($p | decode_deep) else . end
      else . end;

    # Convert arrays whose elements are all objects with a unique "name" into an
    # object keyed by that name, so an inserted item (e.g. a new env var) does
    # not cascade every positional index. Covers container_definitions,
    # environment[], secrets[], portMappings[], ...
    def keyify_named:
      if type == "object" then map_values(keyify_named)
      elif type == "array" then
        ( if (length > 0)
             and all(.[]; type == "object" and has("name"))
             and ((map(.name) | length) == (map(.name) | unique | length))
          then (map({ key: (.name|tostring), value: keyify_named }) | from_entries)
          else map(keyify_named) end )
      else . end;

    # Render a path array as a readable accessor, e.g. ["a",1,"b"] -> a[1].b
    def fmtpath:
      reduce .[] as $k (null;
        if   . == null             then ($k|tostring)
        elif ($k|type) == "number" then "\(.)[\($k)]"
        else "\(.).\($k)" end);

    # true if any prefix of $p is marked unknown (== true) in after_unknown
    def unknown_at($au; $p):
      any(range(0; ($p|length)+1) as $i | $au | getpath($p[:$i]); . == true);

    # Field-level diff of one resource_change: "path: before => after" lines,
    # tagging the leaves that appear in the plan'"'"'s replace_paths.
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

    # ---- filter -------------------------------------------------------------
    select(
        [.resource_changes[]? | select(.change.actions[0] != "no-op")] | length == 3
    ) |
    # ---- report -------------------------------------------------------------
    ["\n","*"*50, "*** \(input_filename | split("/")[-3:]|join("/"))", "*"*50] +
    ([
            [
                .resource_changes[]? | select(.previous_address != null or .change.actions[0] != "no-op")
            ] | {
                moves: [.[] | select(.previous_address != null)],
                changes: [.[] | select(.change.actions[0] != "no-op")]
            }
            | [
                if (.changes | length > 0) then (
                    "Changes (\(.changes|length)):"
                    # Sort by a plain action/address key, then colorize, so the
                    # ANSI escapes never affect ordering.
                    + "\n\([
                        .changes[]
                        | . as $rc
                        | ($rc | field_diff) as $fd
                        | { sort: "\($rc.change.actions|join("/")) \($rc.address)",
                            out: (("  [\($rc.change.actions|join("/"))] - \($rc.address)")
                                    | paint($rc.change.actions|action_color))
                                 + (if (($fd|length) > 0 and ($rc.address | test("module.customer.module.customer_stack.module.ecs_application.aws_cloudwatch_metric_alarm.mcp_ecs_service_cpu") | not)) then "\n" + ($fd|join("\n")) else "" end) }
                    ] | sort_by(.sort) | map(.out) | join("\n"))"
                ) else (null) end,
                if (.moves | length > 0) then (
                  "Moves (\(.moves|length)):"
                  # Uncomment to show the moves
                  # + "\n\(.moves | sort_by(.previous_address) | [
                  #     .[] | "     \(.previous_address)\n  => \(.address)"
                  # ] | join("\n"))"
                ) else (null) end
            ] | map(select(. != null)) | join("\n")
    ]) | join("\n")
    ' \
    "$@"
