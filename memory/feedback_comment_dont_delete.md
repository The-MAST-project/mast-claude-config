---
name: feedback-comment-dont-delete
description: "When disabling something temporarily, comment it out rather than deleting it so the position is preserved for re-enablement"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f236ee82-009b-4a73-b92c-820e17515e81
---

When temporarily disabling a module, config entry, or code path, comment it out rather than deleting it.

**Why:** User wants to preserve the exact location so they know where to put it back when re-enabling. Deletion loses positional context.

**How to apply:** Any time the user says "disable for now", "skip this for now", or similar -- comment out rather than remove, and add a brief note explaining why it is disabled.
