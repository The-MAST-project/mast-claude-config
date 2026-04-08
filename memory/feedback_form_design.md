---
name: Modal form design policy
description: Established design pattern for modal/popup forms in MAST_gui
type: feedback
---

Use Bootstrap horizontal form layout for all modal forms:
- `col-4`: label, `fw-bold text-end` (bold, right-aligned)
- `col-8`: input/widget
- `row mb-2 align-items-center` per field
- Modal footer: Cancel (left) then Save/primary action (right)
- Modal title includes the entity name: "Edit User — username"

**Why:** Established when styling the user edit modal. Consistent across all modal forms in the project.

**How to apply:** Any new modal with a form should follow this layout. Apply to existing modals when they are touched.
