---
name: json_schema_extra formatting style
description: How to format json_schema_extra dicts in Pydantic model files
type: feedback
---

In `json_schema_extra` dicts, use one key-value entry per line. Tooltip string values must never be folded or wrapped across multiple lines — keep the entire `"tooltip": "..."` pair on a single line regardless of length.

**Why:** User explicitly requested this formatting style for readability and to prevent auto-formatter line-wrapping of tooltip content.

**How to apply:** Any time writing or editing `json_schema_extra` in Python Pydantic model files.
