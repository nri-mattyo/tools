# QuickSight for CloudTrail Consolidated Data — Plan

**Status: plan + infra code for review.** Terraform in `aws/quicksight.tf` provisions the
data source/dataset/workgroup/IAM — nothing has been applied. The Athena view
(`quicksight/create_flattened_view.sql`) is a write operation and hasn't been run. The
dashboard's sheets/visuals aren't code yet at all (see §6 for why, and the exact next
step). Everything here goes through the normal approval process (`/terraform-apply` for
the Terraform, explicit approval for the one-time Athena view creation) before anything
touches the account.

## 1. What's already in the account

Checked read-only before designing this:
- QuickSight is already active in `nri-develop` (381492092437), **Enterprise edition**,
  `IDENTITY_POOL`/IAM-federated auth (existing users are IAM-SSO-federated, all currently
  `ADMIN` role — no read-only viewers configured yet)
- One existing Athena data source (`benchmark-results`, workgroup `primary`) — nothing
  CloudTrail-specific yet
- No dedicated Athena workgroup for dashboards exists yet — everything currently shares
  `primary`

Enterprise edition matters: it unlocks row-level security, threshold alerts, and
scheduled email reports, none of which Standard has. Worth using since it's already paid
for.

## 2. Answers this plan is built around

- **Query mode: Direct Query on Athena**, not SPICE — the consolidated table is tens of
  millions of rows already and growing daily; no ingestion step, dashboard always
  reflects the latest partition `convert.py` wrote.
- **Audience: security/ops monitoring + compliance/audit + engineering/cost visibility**,
  all three — the design below (§5, and `DASHBOARD_DESIGN.md`) supports all three rather
  than optimizing for one.
- **Drill-down hierarchy: undecided by design** — built all three candidate hierarchies
  as swappable field-well configurations (see `DASHBOARD_DESIGN.md`) so you can try each
  against real data before committing.

## 3. Architecture

```
Athena view (consolidated_flat)          <- one-time SQL, flattens JSON fields
     |  reads from cloudtrail_logs.consolidated (partition-pruned)
     v
QuickSight Athena data source            <- aws_quicksight_data_source.cloudtrail
  (dedicated workgroup, own bytes-scanned cutoff)
     v
QuickSight dataset (Direct Query)        <- aws_quicksight_data_set.cloudtrail
     v
QuickSight analysis -> dashboard         <- console-built, exported to Terraform later
  Sheet 1: Overview
  Sheet 2: Breakdown (drill-down hierarchy)
  Sheet 3: Deep dive (row-level detail)
```

Why a **view** instead of QuickSight calculated fields for the JSON parsing
(`useridentity.arn` etc.): QuickSight added calculated-field JSON functions a few years
back, but their exact syntax/behavior has shifted across releases and I can't verify the
current form against this account without testing it live. Doing the flattening once in
Athena SQL is unambiguous, testable independently of QuickSight, and reusable by any other
tool that wants the same flattened shape later. It also keeps partition pruning intact —
a view is stored SQL, not a materialization, so a dashboard filter on `year`/`month`/`day`
still prunes the underlying table through the view.

Why a **dedicated Athena workgroup** rather than reusing `primary`: cost visibility (you
can see exactly what the dashboard costs in Athena, separate from ad hoc analyst queries)
and a hard backstop — `bytes_scanned_cutoff_per_query` (default 100 GB in the Terraform)
kills any single query that would otherwise scan the full, ever-growing table.

## 4. Best-practice recommendations (with sourcing)

**Always filter on the partition columns.** Every visual/sheet should carry a
year/month/day (or the `event_timestamp`-derived relative date) filter, defaulted to
something like "last 30 days," not left unbounded. This is standard Athena/QuickSight
guidance for large partitioned tables — an unfiltered visual against a table this size is
both slow and expensive. The dedicated workgroup's bytes-scanned cutoff (§3) is the
backstop for when a filter is accidentally removed, not a substitute for setting one.

**SPICE escape hatch, if Direct Query latency becomes a problem later.** The general
recommendation for billions-of-rows dashboards is: pre-aggregate before loading into
SPICE (e.g., daily rollups by service/region/event name) rather than SPICE-ingesting raw
rows — one write-up describes cutting 50M rows to 200K via daily-total rollups while
keeping drill-down intact by pre-building the hierarchy into the rollup. If Sheet 1's
Overview KPIs/trend feel slow under Direct Query, that's the fix to reach for — a small
SPICE dataset over a pre-aggregated view, not full SPICE ingestion of `consolidated`
itself (impractical given ongoing size). Sheets 2/3 (breakdown, deep dive) should stay on
Direct Query regardless, since they need to reflect current/near-real-time data and
arbitrary drill paths.

**Structure the dashboard as overview → breakdown → deep dive**, one sheet per "act,"
each answering one question — this is the shape used in `DASHBOARD_DESIGN.md`. Avoid
putting the detail table and the KPI cards on the same sheet; it forces every viewer to
scroll past what they don't need.

**Define hierarchies at the visual field-well level**, not as a separate dataset
artifact — QuickSight lets any chart type except pivot tables take an ordered field-well
hierarchy and drill up/down within that one visual. This is what makes trying all three
candidate hierarchies cheap: it's a field reorder, not three separate dashboards.

**Use a QuickSight group as the permission boundary**, not per-user grants. Every current
QuickSight user in this account is `ADMIN` — fine for the handful of people who set this
account up, but as soon as anyone outside that group needs to *view* (not edit) this
dashboard, individually granting each of them is a maintenance trap. `aws_quicksight_group.cloudtrail_viewers`
in the Terraform is the seam for this — grant the group's ARN view-only dashboard
permissions once it exists, add/remove members without touching the dashboard's own
permissions again.

**Row-level security is available and free (Enterprise), consider it if scope ever
narrows.** Not needed for the current all-admin audience, but if this dashboard is later
opened to, say, a team that should only see their own account's events, QuickSight RLS
(a rules dataset mapping principal → allowed row values, e.g. by `recipientaccountid`)
is the standard mechanism — cheaper to design the dataset with this in mind now (the
`recipientaccountid`/`source_trail` columns already exist in the flattened view for
exactly this) than to retrofit later.

**Threshold alerts (Enterprise) for the error-rate KPI.** Once Sheet 1's error-rate KPI
exists, QuickSight can email/notify when it crosses a threshold — worth wiring up given
the security/ops monitoring use case, and it's a checkbox on an existing visual, not new
infra.

**Iterate the dashboard in-console first, then codify.** See §6 — this is as much a
build-workflow recommendation as a configuration one.

## 5. Cost/ops guardrails specific to this dataset

- The consolidated table already spans 2M+ raw source objects across 4 AWS accounts'
  worth of CloudTrail history (per the parallel cleanup effort in
  `../cleanup/CLEANUP_PLAN.md`) and grows daily — treat "unfiltered scan" as a real cost
  risk, not a theoretical one.
- `source_trail` (derived in the flattened view) doubles as a live check on the
  `api-events`/`main-cloudtrail` duplication described in the cleanup plan — once that
  cleanup executes, this dashboard is a good place to visually confirm the duplicate
  volume actually disappears.
- CloudWatch metrics are enabled on the dedicated workgroup
  (`publish_cloudwatch_metrics_enabled = true`) — set a billing/usage alarm on Athena
  bytes-scanned for this workgroup specifically once it's live, so a filter regression
  shows up before the monthly bill does.

## 6. Recommended build workflow

1. Get this plan + Terraform approved and applied (workgroup, IAM, data source, dataset,
   viewers group) — mechanical, low-risk, reviewed via `/terraform-apply` as usual.
2. Run the one-time Athena view creation (`quicksight/create_flattened_view.sql`) — a
   write operation, needs its own explicit approval, separate from the Terraform apply.
3. In the QuickSight console, build an analysis against the new dataset following
   `DASHBOARD_DESIGN.md` — three sheets, try all three hierarchy variants on Sheet 2,
   decide which one(s) to keep.

   *Why console-first rather than hand-written Terraform for this part*: QuickSight's
   `aws_quicksight_analysis`/`aws_quicksight_dashboard` `definition` schema is deep
   (sheets → visuals → chart_configuration → field_wells, several layers down) and the
   console gives immediate visual feedback on whether a field-well/hierarchy/filter
   choice actually looks right — something no amount of careful HCL authoring replaces
   for a first pass. AWS's own QuickSight-on-Terraform guidance leans the same way:
   prototype visually, then lock in via export.
4. Publish as a dashboard once the analysis looks right.
5. Export the finished definition and fold it into Terraform for real change tracking
   going forward:
   ```bash
   aws quicksight describe-dashboard-definition \
     --aws-account-id 381492092437 --dashboard-id <id> \
     --profile nri-develop --region us-east-1 > dashboard-definition.json
   ```
   (exact mapping notes in `DASHBOARD_DESIGN.md`'s last section)
6. From that point on, dashboard changes go through `terraform plan`/`apply` like the
   rest of this infra, rather than untracked console edits.

## Files in this plan

- [`create_flattened_view.sql`](./create_flattened_view.sql) — one-time Athena view,
  needs approval to run
- [`DASHBOARD_DESIGN.md`](./DASHBOARD_DESIGN.md) — sheet layout and the three drill-down
  hierarchy options
- [`../aws/quicksight.tf`](../aws/quicksight.tf) — Terraform for workgroup, IAM, data
  source, dataset, viewers group (new variables also added to `../aws/variables.tf`,
  outputs to `../aws/outputs.tf`)

## Sources consulted for best practices

- [Tips and tricks for high-performant dashboards in Amazon QuickSight (AWS blog)](https://aws.amazon.com/blogs/big-data/tips-and-tricks-for-high-performant-dashboards-in-amazon-quicksight/)
- [Amazon QuickSight — Best practices Part 1 (AWS Builder Center)](https://builder.aws.com/content/2rfpwl1gNpQIMhmTGuJxq0E9sl2/amazon-quicksight-best-practices-part-1)
- [Adding drill-downs to visual data in Amazon QuickSight (AWS docs)](https://docs.aws.amazon.com/quick/latest/userguide/adding-drill-downs.html)
- [`aws_quicksight_data_set` / `aws_quicksight_analysis` (Terraform AWS provider docs)](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/quicksight_data_set)
