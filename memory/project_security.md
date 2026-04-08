---
name: Security approach — JWT and auth
description: Auth decisions: JWT everywhere, OAuth providers, signup policy, future domain filtering
type: project
---

## JWT
JWT will be used for authentication across all MAST API access points.
- Django issues JWTs on login (djangorestframework-simplejwt)
- FastAPI backends validate JWT on every request via middleware
- mast-api.sh reads token from ~/.mast/token, injects as `Authorization: Bearer` header
- Shell script checks token expiry automatically before each call (decode `exp` from JWT payload, re-login if expired)
- GUI: standard short-lived access token + refresh token flow
- Token carries user identity + roles, enabling per-user audit trails (e.g. in plan events)

## OAuth providers
- Google and GitHub via django-allauth
- Credentials stored in .env (never committed), read via python-decouple config()
- Env vars: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET
- One-time manual registration per provider; all user flows are automated after that

## Roles model
Roles are Django Groups with pre-assigned permissions. Additive (user can be in multiple groups). Admin picks role at approval time — no default.
No is_superuser — highest privilege is the Admin group.

Permissions:
- can_view
- can_submit_plans
- can_manage_plans
- can_execute_plans  (execute a plan or generate+execute a batch; Operator only)
- can_low_level_control  (renamed from can_use_controls — for operators to unstick things)
- can_change_configuration
- can_manage_users

Groups:
- Guest: can_view  (temporary — may be removed once everything works)
- Scientist: can_view, can_submit_plans  (submits observation plans)
- Operator: can_view, can_submit_plans, can_manage_plans, can_execute_plans, can_low_level_control  (runs the system)
- Admin: all permissions

Use Django's /admin/ panel for user management instead of custom views.
- Admin-group users get is_staff=True (set automatically via signal when added to Admin group)
- No is_superuser anywhere
- Custom admin views (admin_users, admin_user_edit, approve/reject) to be replaced by customized Django ModelAdmin
- The hardcoded 'admin'/'physics' user in RegisteredUserBackend must be removed; bootstrap via management command instead

## Signup/login policy
- Currently: any user with valid credentials (local or OAuth) may sign up and log in
- Admin approval is still required (is_registered flag) before first login
- Future: admin UI to manage email domain whitelist/blacklist (not implemented yet)

**Why:** Keep it simple now; domain filtering is a future enhancement controlled by admin.

**How to apply:** Do not add domain filtering logic yet. When implementing, add it to CustomSocialAccountAdapter and expose the whitelist/blacklist as an admin-editable model.
