# NFC Foosball — Backend MVP (v0.1)

Backend stack:
- Supabase Auth
- PostgreSQL
- Supabase Edge Function (`match-api`)
- React/Vite frontend will call the Edge Function
- ESP32-S3 device support is reserved in the schema; device pairing is not enabled yet.

## Match rules in this MVP

- Singles: exactly 1 player per team.
- Doubles: exactly 2 players per team.
- A table can have only one active match (`open`, `in_progress`, or `pending_confirmation`).
- The creator is automatically Team A.
- Players join by selecting Team A or B.
- A match can start only when both teams are full.
- Any participant can propose a non-tied result.
- Every participant, including the proposer, must explicitly accept the same proposed result.
- A rejection clears confirmations and returns the match to `in_progress`; a new score must be proposed.
- Elo is separate for singles and doubles; initial rating 1200, K=32.
- Elo changes are applied once, in the same database transaction that completes the match.

## 1. Create a Supabase project

1. Create a project at https://supabase.com/dashboard.
2. Open **Project Settings → API** and copy:
   - Project URL
   - `anon` / publishable key
3. Keep the `service_role` / secret key private. It is not needed by this MVP Edge Function.
4. In **Authentication → URL Configuration**, configure your local and production frontend URLs when the frontend is added.

## 2. Apply the migration

Install the Supabase CLI, then from this repository root:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

Alternatively, paste `supabase/migrations/0001_initial_schema.sql` into the Supabase SQL Editor and run it once.

Do not run both methods against the same project.

## 3. Configure Edge Function secrets

```bash
supabase secrets set SUPABASE_URL="https://YOUR_PROJECT_REF.supabase.co"
supabase secrets set SUPABASE_ANON_KEY="YOUR_ANON_OR_PUBLISHABLE_KEY"
```

These are not privileged secrets. The Edge Function validates the caller's JWT and passes it through to Postgres. Do not set or expose a service-role key for this function.

## 4. Deploy the API

```bash
supabase functions deploy match-api
```

The function URL is:

```text
https://YOUR_PROJECT_REF.supabase.co/functions/v1/match-api
```

Supabase verifies JWTs at the gateway by default for this function. The function also validates the JWT with `auth.getUser()`.

## 5. Local development

```bash
supabase start
supabase functions serve match-api --env-file supabase/.env.local
```

Create `supabase/.env.local` (never commit it):

```dotenv
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_ANON_KEY=YOUR_LOCAL_ANON_KEY
```

## 6. Call the API

All requests are POST requests with a JSON body and an authenticated Supabase access token.

Example:

```bash
curl -X POST \
  "https://YOUR_PROJECT_REF.supabase.co/functions/v1/match-api" \
  -H "Authorization: Bearer USER_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action":"create_match","table_slug":"main","format":"doubles"}'
```

Supported actions:

### Create a match

```json
{"action":"create_match","table_slug":"main","format":"singles"}
```

The creator is automatically added to Team A.

### Join a match

```json
{"action":"join_match","match_id":"UUID","team":"B"}
```

### Start a match

```json
{"action":"start_match","match_id":"UUID"}
```

Only the creator can start the match, and both teams must be full.

### Propose a result

```json
{"action":"submit_result","match_id":"UUID","team_a_score":10,"team_b_score":7}
```

### Confirm or reject a result

```json
{"action":"confirm_result","match_id":"UUID","accepted":true}
```

The caller must be a participant. All participants must accept for the result to become official.

### Read a match

```json
{"action":"get_match","match_id":"UUID"}
```

### Read leaderboard

```json
{"action":"get_leaderboard","format":"singles","limit":20}
```

## 7. Test with two or four accounts

Create test users through Supabase Auth (or enable email/password sign-up in the dashboard). Each user needs a profile; the migration creates one automatically after an Auth user is inserted.

For singles:
1. User A creates a singles match.
2. User B joins Team B.
3. User A starts the match.
4. A participant submits the result.
5. Both players accept it.

For doubles:
1. User A creates a doubles match (Team A).
2. User B joins Team A.
3. Users C and D join Team B.
4. The creator starts the match.
5. Submit and obtain four explicit confirmations.

## 8. Important security notes

- Never put a Supabase service-role key in React, the ESP32, Git, or this repository.
- The browser and device must not write directly to match, participant, confirmation, or rating tables.
- The SQL RPCs are `SECURITY DEFINER`, but explicitly check `auth.uid()` and enforce the match rules.
- RLS is enabled. Direct table writes are intentionally unavailable to ordinary users.
- This MVP does not yet implement email verification policy, rate limiting, account deletion workflow, admin tools, device pairing, score correction after completion, or tournament management.
- The table URL identifies a table; it does not authenticate a player. Users must log in.
- For production, configure Auth email verification, CAPTCHA/rate limits where appropriate, backups, and a privacy policy.

## 9. Repository layout

```text
nfc-foosball/
├── README.md
└── supabase/
    ├── config.toml
    ├── migrations/
    │   └── 0001_initial_schema.sql
    └── functions/
        └── match-api/
            └── index.ts
```
