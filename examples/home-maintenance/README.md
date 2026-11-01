# Example: home maintenance tracker with SilverBullet

This example shows how SilverBullet can be used as a simple maintenance tracker for a house or a
smart home: one page per task, and an overview page with live tables.

> **All data is fictional.** Items, suppliers, e-mail addresses (`.example`) and dates are made up.

## Structure

```
Maintenance/
├── Overview.md           ← dashboard with Space Lua queries (SilverBullet 2.x)
├── Smoke-Detectors.md    ← planned task (overdue)
├── Heating-Service.md    ← task in progress
└── Window-Seals.md       ← finished task
```

## Frontmatter schema

Every task file contains this YAML frontmatter block:

```yaml
---
item: "Smoke detectors"
task: "Replace batteries"
status: "Planned"           # Planned | In progress | Done | Cancelled
created_at: "2026-10-15"    # ISO date
due_at: "2026-10-29"        # ISO date or empty
area: "Whole house"
supplier: "Hardware store"
contact: "shop@example-hardware.example"
notes: "Short note"
---
```

## Installation

1. Copy the contents of `Maintenance/` into your SilverBullet space
2. Open `Maintenance/Overview.md` – the tables are generated from the frontmatter automatically

> **Mind the folder name:** all queries in `Overview.md` filter on the folder `Maintenance/`
> (`p.name:startsWith("Maintenance/")`). If you put the files in a different folder, you have to adjust
> this path in every query. Otherwise the tables stay empty.

The queries use the Space Lua syntax of SilverBullet 2.x (`${query[[ … ]]}`). The old
```` ```query ```` syntax from SilverBullet 1.x does not work there anymore.

## Use with Claude

Prerequisite: the MCP bridge is enabled and the `silverbullet-ai` plug is installed in the space
(see the [add-on documentation](../../silverbullet/DOCS.md)).

```bash
# Claude Code: add the MCP server
claude mcp add --transport http silverbullet http://<ha-ip>:3033/mcp \
  --header "Authorization: Bearer <token>"
```

**Example prompts:**
- "Create a maintenance task for the garden irrigation: winterize the pipes, planned, due in 14 days."
- "Show me all overdue maintenance tasks."
- "Set the status of the heating service to 'Done'."
