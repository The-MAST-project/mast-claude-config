---
name: SSH key auth on Windows
description: How to add SSH public keys for auth on Windows OpenSSH — use administrators_authorized_keys not ~/.ssh/authorized_keys
type: feedback
---

On Windows machines (mastw, mast-wis-spec), add the public key to:
`C:\ProgramData\ssh\administrators_authorized_keys`

NOT to `C:\Users\mast\.ssh\authorized_keys`.

**Why:** Windows OpenSSH uses the system-wide `administrators_authorized_keys` file for users in the Administrators group, ignoring the per-user `authorized_keys`.

**How to apply:** When setting up SSH key auth to any MAST Windows machine, always use the `administrators_authorized_keys` path.
