---
name: Post-change instructions
description: Always tell the user what action is needed after making changes
type: feedback
---

After every set of changes, always tell the user which of these apply:
- Restart backend (FastAPI/MAST control services)
- Restart Django (the MAST_gui Django server)
- Refresh page (browser refresh is enough)

**Why:** User explicitly requested this so they know what to do after each change without having to ask.

**How to apply:** End every response where code/config was changed with a brief "→ Restart Django" or "→ Refresh page" etc. Only mention what's actually needed for that specific change.
