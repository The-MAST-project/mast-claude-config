---
name: project-mongodb-setup
description: MongoDB installed and seeded on this host machine (mast-wis-control role); VM test-mode hostname routing via bootstrap-winrm.ps1 -VmTestRun
metadata: 
  node_type: memory
  type: project
  originSessionId: e0f39916-a250-4b47-9a7b-e2260f6a6a28
---

MongoDB 8.3.1 installed on this machine (labcomp2) via winget, running as Windows service on localhost:27017.
Also installed: MongoDB Shell (mongosh 2.8.3) and MongoDB Database Tools (100.14.1).

Seed data loaded from MAST_common/mongo_seeds/2024-06-13/mast.bkp/mast/ via mongorestore.
Database: mast. Collections: groups (3), units (3), services (3), users (7), sites (2).

**Why:** This machine plays the role of mast-wis-control for local development. In production, mast-wis-control is a separate server.

**VM test routing:** bootstrap-winrm.ps1 now has a -VmTestRun switch. When passed, it adds
`192.168.56.1  mast-wis-control  # MAST-VM-TEST-ONLY` to the VM's hosts file so the MongoDB
client inside the VM connects back to this host machine. The entry is idempotent and clearly
marked for removal before production use.

Binaries:
- mongod: C:\Program Files\MongoDB\Server\8.3\bin\mongod.exe
- mongorestore: C:\Program Files\MongoDB\Tools\100\bin\mongorestore.exe
- mongosh: C:\Users\labcomp2\AppData\Local\Programs\mongosh\mongosh.exe
