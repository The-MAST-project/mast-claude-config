---
name: Sidebar submenu implementation
description: How Safety and Manage collapsible submenus work in the sidebar
type: project
---

Sidebar submenus (Safety, Manage) use Bootstrap Collapse — NOT custom JS toggle.

**Why:** Custom `style.display = 'block'` approach failed (arrow toggled but content never showed). Switched to Bootstrap's `data-bs-toggle="collapse"` which is reliable.

**Trigger div:**
```html
<div class="sidebar-item" data-bs-toggle="collapse" data-bs-target="#safety-submenu" aria-expanded="false">
```

**Submenu div:**
```html
<div class="collapse sidebar-submenu" id="safety-submenu">
```

**JS** (in sidebar.html `<script>`): Listens to `show.bs.collapse` / `hide.bs.collapse` events to toggle arrow between `bi-chevron-right` and `bi-chevron-down`. Also auto-opens submenus containing `.sidebar-subitem.active` on DOMContentLoaded.

**Collapsed sidebar:** `.sidebar-collapsed .sidebar-submenu { display: none !important }` still correctly overrides Bootstrap's `.show` class when sidebar is toggled narrow.
