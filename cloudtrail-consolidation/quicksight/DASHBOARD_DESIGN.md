# Dashboard design: sheets, visuals, and the three drill-down hierarchies

**Status: a v1 of this is live.** Contrary to the original plan below (build in-console,
since the API's `definition` schema looked too deep to hand-author reliably), it turned out
tractable to build directly via `create-analysis`/`create-dashboard` with a hand-authored
`Definition` JSON, validated empirically against the real API (isolating and fixing a few
real issues along the way — a missing dataset column, and a `CalculatedMeasureField` field-well
shape that the service rejects in favor of a top-level `CalculatedFields` declaration
referenced like a normal column). The exact JSON that's live is checked in at
[`dashboard-definition.json`](./dashboard-definition.json) — see "What's actually built" below
for what it covers and what's still open. The original section-by-section design (including
the two hierarchy variants not yet wired up) is kept as-is below since it's still the plan for
extending v1.

- Analysis: `arn:aws:quicksight:us-east-1:381492092437:analysis/cloudtrail-consolidation-analysis`
- Dashboard: `arn:aws:quicksight:us-east-1:381492092437:dashboard/cloudtrail-consolidation-dashboard`
- Console URL: `https://us-east-1.quicksight.aws.amazon.com/sn/dashboards/cloudtrail-consolidation-dashboard`

## What's actually built (v1)

- **Overview**: 3 KPIs (total events, error rate via a top-level `error_rate_pct` calculated
  field, distinct actors) + a daily trend line colored by `source_trail`.
- **Breakdown**: one bar chart with a real drill-down `ExplicitHierarchy`
  (`awsregion → eventsource → eventname`) — hierarchy variant 1 below, region-first. Click a
  bar to drill down within the same visual.
- **Deep dive**: a detail table (`event_timestamp, eventsource, eventname, awsregion,
  actor_arn, actor_username, sourceipaddress, errorcode, recipientaccountid, source_trail`).

**Not yet built** (still open, per the design below): the account-first and actor-first
hierarchy variants, cross-sheet click-through filter actions between sheets, a shared relative-
date parameter control, and any default date-range filter (§ "cost-control" caveat in
QUICKSIGHT_PLAN.md still applies — there's no default filter yet, so an unfiltered view of
Breakdown/Deep dive scans the whole table). Iterating on these in the console is still
perfectly reasonable — anything changed there can be re-exported the same way this v1 was
captured (see "Exporting" below), it just isn't required anymore since the API path worked.

## Structure: three sheets, one per "act"

QuickSight's own drill-down guidance and general dashboard-design practice converge on the
same shape: an overview sheet a viewer can absorb in seconds, a breakdown sheet for
comparing categories, and a deep-dive sheet for the actual audit-grade detail. Click-through
(a viewer clicks a bar/segment) should move left-to-right across these three, not force a
single overloaded sheet to do everything.

**Sheet 1 — Overview** (default landing sheet, filtered to a relative last-30-days window)
- KPI cards: total events, error rate (`is_error`), distinct actors (`actor_arn`), distinct
  services (`eventsource`)
- Line chart: event volume over time, colored by `source_trail` (also doubles as a live view
  into the `api-events`/`main-cloudtrail` overlap from
  [../cleanup/CLEANUP_PLAN.md](../cleanup/CLEANUP_PLAN.md) — useful after that cleanup runs,
  to visually confirm the duplicate volume actually drops)
- Small multiples or a stacked bar: events by `awsregion`

**Sheet 2 — Breakdown** (the drill-down hierarchy lives here)
- One large bar chart / tree map with the field well set to a **hierarchy** (see the three
  options below) — clicking a bar drills one level down within the same visual
- A parallel table showing top `eventname` values for whatever's currently selected
- Every visual here should have a control-panel filter for `source_trail` and the
  year/month/day partition fields, defaulted to a relative date range — see
  QUICKSIGHT_PLAN.md's cost-control section for why this default matters

**Sheet 3 — Deep dive**
- Detail table: `event_timestamp, eventsource, eventname, awsregion, actor_arn, actor_username,
  sourceipaddress, errorcode, errormessage, recipientaccountid, orig_file` — filtered by
  whatever was selected upstream via a QuickSight **filter action** (URL/on-click filter
  propagation from Sheet 2), not a manual re-filter
- This is the sheet that answers "who did what, when" for compliance/audit use — link
  `actor_arn`/`orig_file` back to source data if a reviewer needs to pull the raw event

## The three drill-down hierarchies

You asked to see all three rather than commit to one up front — build all three as
alternate field-well configurations on Sheet 2's main visual (QuickSight lets you swap a
visual's hierarchy without rebuilding it — drag a different field order into the field well,
or keep three near-identical visuals side by side on Sheet 2 during the decision phase, then
delete the two you don't keep).

1. **Time → Region → Service → Event name → Actor**
   Field well order: `event_timestamp` (year/month/day auto-levels) → `awsregion` →
   `eventsource` → `eventname` → `actor_arn`.
   Best if the team thinks in terms of "when did this pattern start" first, then narrows by
   where/what/who. Natural fit for the security/ops monitoring use case (anomaly hunting
   usually starts from a time-series spike).

2. **Account → Service → Event name → Time → Actor**
   Field well order: `recipientaccountid` → `eventsource` → `eventname` → `event_timestamp` →
   `actor_arn`.
   Best once this dashboard spans more than one AWS account (you already have four —
   `381492092437`, `637423466983`, `293034550673`, plus whichever account the consolidated
   table itself lives in) and want account-to-account comparison as the first cut, before
   time enters the picture at all.

3. **Actor → Service → Event name → Time**
   Field well order: `actor_arn` (or `actor_username` if you want human-readable) →
   `eventsource` → `eventname` → `event_timestamp`.
   Best fit for the compliance/audit use case — "what did this identity do" is the starting
   question, not "what happened at this time."

All three reuse the exact same dataset/fields — nothing about the Terraform or the Athena
view needs to change to try any of them. Pick whichever feels most natural once you're
clicking through real data; it's a field-well reorder, not a rebuild.

## Cross-sheet interactivity checklist

- Wire an **on-click filter action** from Sheet 1's region bar → Sheet 2 (jump straight to
  that region's breakdown)
- Wire an on-click filter action from Sheet 2's hierarchy visual → Sheet 3 (drill to
  row-level detail for whatever's selected)
- Add a **parameter-driven relative date control** (last 24h / 7d / 30d / 90d / custom) once,
  at the dashboard level, so all three sheets stay in sync rather than each having its own
  independent date filter

## Exporting the finished design (and re-syncing after console edits)

`dashboard-definition.json` in this directory is the definition currently live for both the
analysis and the dashboard (both were created from the same file). If you make further edits
in the console, re-export and overwrite it the same way this v1 was captured:
```bash
aws quicksight describe-dashboard-definition \
  --aws-account-id 381492092437 --dashboard-id cloudtrail-consolidation-dashboard \
  --profile nri-develop --region us-east-1 --query Definition > quicksight/dashboard-definition.json
```
To push a locally-edited `dashboard-definition.json` back up without going through the
console at all (the same path used to build v1):
```bash
aws quicksight update-analysis --aws-account-id 381492092437 \
  --analysis-id cloudtrail-consolidation-analysis --name "CloudTrail Consolidated" \
  --definition file://quicksight/dashboard-definition.json --profile nri-develop --region us-east-1
aws quicksight update-dashboard --aws-account-id 381492092437 \
  --dashboard-id cloudtrail-consolidation-dashboard --name "CloudTrail Consolidated" \
  --definition file://quicksight/dashboard-definition.json --profile nri-develop --region us-east-1
```
Both are write operations against live QuickSight resources — same approval rule as everything
else in this account. Migrating this to a Terraform-managed `aws_quicksight_dashboard` resource
(same JSON, HCL block syntax instead of raw JSON) remains a reasonable next step for
change-tracking, just no longer a blocking prerequisite the way the original plan assumed.
