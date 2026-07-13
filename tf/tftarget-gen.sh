#!/usr/bin/env bash
#
# tftarget-gen.sh — extract "create" records for a given resource out of a set
# of Terraform plan JSONs and emit a standalone root module that creates them
# all at once, plus a manifest that records where each one came from so the
# resources can later be imported back into their owning stacks.
#
# Usage:
#   ./tftarget-gen.sh [plan.json ...]          # defaults to */.terraform/*.tfplan.json
#   MATCH='aws_cloudwatch_metric_alarm.mcp_ecs_service_cpu' ./tftarget-gen.sh
#
# Output (under .tftarget/<date>/):
#   main.tf       root module: provider + one resource block per extracted create
#   manifest.tsv  customer  plan_file  source_address  import_id  target_resource
#   README.md     provenance + how to apply and import back
#
# NOTE: this generates resources from the plan's `after` values. It is built
# for the uniform mcp_ecs_service_cpu alarm; review main.tf before applying if
# you point MATCH at a different resource type.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_DEFAULT_PROFILE="${AWS_DEFAULT_PROFILE:-NRI_prod}"

MATCH="${MATCH:-aws_cloudwatch_metric_alarm.mcp_ecs_service_cpu}"
RES_TYPE="${RES_TYPE:-aws_cloudwatch_metric_alarm}"
REGION="${REGION:-us-east-2}"
DATE="$(date +%F)"
OUT_DIR="${OUT_BASE:-$SCRIPT_DIR/.tftarget}/$DATE"

# Markdown literals as vars so HEREDOCs can stay unquoted (interpolating) without
# escaping backticks — `bt` = inline code, `btb` = fenced block.
bt='`'
btb='```'

# Default glob if no files were passed.
if [ "$#" -eq 0 ]; then
  cd "$SCRIPT_DIR"
  set -- */.terraform/*.tfplan.json
fi

mkdir -p "$OUT_DIR"

# Emit one compact JSON object per matching create:
#   { customer, plan_file, address, import_id, block }
# `block` is the rendered HCL resource (with a provenance comment header).
records="$(jq -c --arg match "$MATCH" --arg res "$RES_TYPE" '
    # --- HCL emitters ---
    def esc: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"");
    def scalar_hcl:
      if   type == "string"  then "\"" + esc + "\""
      elif type == "boolean" then tostring
      elif type == "number"  then tostring
      else tojson end;
    def inline_hcl:
      if type == "object" then
        "{ " + ([ to_entries[] | "\"\(.key|esc)\" = \(.value|scalar_hcl)" ] | join(", ")) + " }"
      elif type == "array" then
        "[" + ([ .[] | scalar_hcl ] | join(", ")) + "]"
      else scalar_hcl end;
    # writable args only: drop nulls, computed (id/arn/tags_all), empty lists.
    def args_hcl:
      to_entries
      | map(select(
            (.value != null)
            and ((.key == "id" or .key == "arn" or .key == "tags_all") | not)
            and (((.value | type) == "array" and (.value | length) == 0) | not)
        ))
      | sort_by(.key)
      | map("  \(.key) = \(.value | inline_hcl)")
      | join("\n");

    .resource_changes[]?
    | select((.address | test($match)) and .change.actions == ["create"])
    | (input_filename)            as $pf
    | ($pf | split("/")[-3])      as $customer
    | ($customer | gsub("[^A-Za-z0-9_-]"; "_")) as $label
    | .change.after               as $a
    | ($a.alarm_name // $a.name // $a.id) as $import_id
    # First ARN found anywhere in `after` -> the account/region this resource
    # belongs to (arn:aws:<svc>:<region>:<account>:...). Used to self-configure
    # the wrong-account guard below.
    | ([ $a | .. | strings | select(startswith("arn:aws:")) ][0]) as $arn
    | { customer: $customer,
        plan_file: $pf,
        address: .address,
        label: $label,
        import_id: $import_id,
        account: (if $arn then ($arn | split(":")[4]) else null end),
        region:  (if $arn then ($arn | split(":")[3]) else null end),
        block: ( "# source plan : \($pf)\n"
               + "# import into : \(.address)\n"
               + "# import id    : \($import_id)\n"
               + "resource \"\($res)\" \"\($label)\" {\n"
               + ($a | args_hcl) + "\n}" ) }
  ' "$@" | jq -s 'sort_by(.customer)')"

count="$(jq 'length' <<<"$records")"

# Derive the account/region these resources belong to, straight from the plan
# ARNs. If the plans span more than one account we refuse to generate — that
# would mean a single root module targeting multiple accounts.
acct_count="$(jq '[.[].account] | map(select(. != null)) | unique | length' <<<"$records")"
if [ "$acct_count" -gt 1 ]; then
  echo "error: plans span multiple AWS accounts: $(jq -c '[.[].account]|unique' <<<"$records")" >&2
  echo "       generate per-account (filter the plan files passed in)." >&2
  exit 1
fi
EXPECT_ACCT="$(jq -r '[.[].account] | map(select(. != null)) | unique | (.[0] // "")' <<<"$records")"
EXPECT_REGION="$(jq -r '[.[].region]  | map(select(. != null)) | unique | (.[0] // "")' <<<"$records")"
EXPECT_REGION="${EXPECT_REGION:-$REGION}"
PROVIDER_REGION="$EXPECT_REGION"

# --- main.tf -----------------------------------------------------------------
# Header via HEREDOC; resource blocks appended from the extracted records.
cat > "$OUT_DIR/main.tf" <<EOF
# GENERATED by tftarget-gen.sh on $DATE — DO NOT hand-edit; regenerate instead.
#
# One-shot root module that creates the $count '$MATCH'
# resources that the per-customer plans reported as needing creation.
# Local state only (no backend) — this module is a bulk-creation vehicle;
# see README.md for the import-back procedure and provenance.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.39" }
  }
}

provider "aws" {
  region = "$PROVIDER_REGION"
}

# ---------------------------------------------------------------------------
# Wrong-account / wrong-region guard.
#
# These resources were extracted from plans in account $EXPECT_ACCT / region
# $EXPECT_REGION. The defaults below are baked in from those plans; override
# only if you know better. The terraform_data precondition is evaluated at
# PLAN time, so a credential/region mismatch aborts before anything is created.
# ---------------------------------------------------------------------------
variable "expected_account_id" {
  description = "AWS account these resources must be created in."
  type        = string
  default     = "$EXPECT_ACCT"
}

variable "expected_region" {
  description = "AWS region these resources must be created in."
  type        = string
  default     = "$EXPECT_REGION"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "terraform_data" "account_guard" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.expected_account_id
      error_message = "Wrong AWS account: credentials resolve to \${data.aws_caller_identity.current.account_id}, expected \${var.expected_account_id}. Aborting before any resource is created."
    }
    precondition {
      condition     = data.aws_region.current.name == var.expected_region
      error_message = "Wrong AWS region: provider resolves to \${data.aws_region.current.name}, expected \${var.expected_region}. Aborting before any resource is created."
    }
  }
}

EOF
jq -r '.[].block' <<<"$records" | sed 's/[[:space:]]*$//' >> "$OUT_DIR/main.tf"
printf '\n' >> "$OUT_DIR/main.tf"

# Canonicalize alignment/spacing (best-effort; ignore if terraform is absent).
terraform fmt "$OUT_DIR/main.tf" >/dev/null 2>&1 || true

# --- manifest.tsv ------------------------------------------------------------
{
  printf 'customer\tplan_file\tsource_address\timport_id\ttarget_resource\n'
  jq -r --arg res "$RES_TYPE" \
    '.[] | [.customer, .plan_file, .address, .import_id, "\($res).\(.label)"] | @tsv' \
    <<<"$records"
} > "$OUT_DIR/manifest.tsv"

# --- README.md ---------------------------------------------------------------
cat > "$OUT_DIR/README.md" <<EOF
# tftarget — $DATE

Generated by ${bt}tftarget-gen.sh${bt} from $count Terraform plan(s) that reported
${bt}$MATCH${bt} as needing creation.

## Files
- ${bt}main.tf${bt} — standalone root module (local state) that creates all $count
  resources in one apply. Each block is preceded by a comment recording the
  **source plan**, the **owning module address**, and the **import id**.
- ${bt}manifest.tsv${bt} — machine-readable provenance: ${bt}customer · plan_file ·
  source_address · import_id · target_resource${bt}.

## Apply (bulk-create)
${btb}bash
cd $OUT_DIR
terraform init
terraform apply        # creates all $count resources in AWS
${btb}

These resources belong to account **$EXPECT_ACCT** / region **$EXPECT_REGION**.
${bt}main.tf${bt} bakes those in as ${bt}expected_account_id${bt} / ${bt}expected_region${bt} and
guards them with a ${bt}terraform_data${bt} precondition that reads the live
${bt}aws_caller_identity${bt} / ${bt}aws_region${bt}. If your active credentials or provider
region don't match, the **plan aborts before anything is created** — so a
wrong-account apply is structurally impossible. Override the defaults only if
you intend to target a different account/region.

## Hand ownership back to the customer stacks
The customer stacks still think they need to create these (their state doesn't
know the resource now exists). For each row in ${bt}manifest.tsv${bt}, add an import
to that customer's root module so its next plan adopts the existing resource
instead of recreating it. The ${bt}import_id${bt} for ${bt}$RES_TYPE${bt} is the alarm name.

${bt}import {}${bt} block (Terraform >= 1.5), placed in the customer's dir:
${btb}hcl
import {
  to = <source_address>
  id = "<import_id>"
}
${btb}

…or the CLI form:
${btb}bash
# from the customer's directory (column 2 gives the plan path -> the dir is its first 2 segments)
terraform import '<source_address>' '<import_id>'
${btb}

⚠️ Dual-ownership: once a resource is imported into its customer stack, remove
it from THIS module's state so it isn't managed twice —
${bt}terraform state rm '<target_resource>'${bt} here (this does NOT delete the AWS
resource). Only ${bt}terraform destroy${bt} this module before importing, never after.
EOF

echo "Wrote $count resources to:"
echo "  $OUT_DIR/main.tf"
echo "  $OUT_DIR/manifest.tsv"
echo "  $OUT_DIR/README.md"
