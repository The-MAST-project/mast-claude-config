---
name: ORCID account check
description: Reminder to check if an ORCID developer account exists or needs to be created for MAST OAuth
type: project
---

Check whether Weizmann / MAST already has an ORCID developer account registered, or if one needs to be created at orcid.org/developer-tools.

Needed for: ORCID OAuth login via allauth (client_id + secret → ORCID_CLIENT_ID, ORCID_CLIENT_SECRET in .env).

Redirect URI to register: https://mast-wis-control:8010/accounts/orcid/login/callback/
