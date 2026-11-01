# Maintenance – overview

This page lists all maintenance tasks and their status. The tables are generated from the frontmatter of the task pages with Space Lua queries (SilverBullet 2.x).

> **Note:** All queries below filter on the folder `Maintenance/`. If you keep these pages in a different folder, adjust the path in every query.

## All tasks

${query[[
  from p = index.tag "page"
  where p.item and p.name:startsWith("Maintenance/")
  order by p.created_at desc
  select {Item = p.item, Task = p.task, Status = p.status, Created = p.created_at}
]]}

## Open tasks (not finished)

${query[[
  from p = index.tag "page"
  where p.item and p.name:startsWith("Maintenance/")
    and p.status ~= "Done" and p.status ~= "Cancelled"
  order by p.due_at
  select {Item = p.item, Task = p.task, Status = p.status, Due = p.due_at}
]]}

## Overdue tasks

Tasks whose due date has already passed:

${query[[
  from p = index.tag "page"
  where p.item and p.name:startsWith("Maintenance/")
    and p.due_at and p.due_at ~= "" and p.due_at < os.date("%Y-%m-%d")
    and p.status ~= "Done" and p.status ~= "Cancelled"
  order by p.due_at
  select {Item = p.item, Status = p.status, Due = p.due_at}
]]}

## Statistics

${query[[
  from p = index.tag "page"
  where p.item and p.name:startsWith("Maintenance/")
  group by p.status
  select {Status = key, Count = #group}
]]}

---

## Manage with Claude via MCP

Prerequisite: the MCP bridge is enabled and the `silverbullet-ai` plug is installed in the space (see the add-on documentation).

### Create a new task

Tell Claude Code (after the MCP setup):

> "Create a new maintenance task for 'Garden irrigation', task 'Winterize the pipes', status 'Planned', created today, due in 14 days, area 'Garden'."

Claude then creates the file `Maintenance/Garden-Irrigation.md` with matching frontmatter.

### Update a status

> "Set the status of the heating service to 'Done' and clear the due date."

### Ask for overdue tasks

> "Which maintenance tasks are overdue?"

### Connect Claude Code

```bash
claude mcp add --transport http silverbullet http://<ha-ip>:3033/mcp \
  --header "Authorization: Bearer <your-mcp-token>"
```
