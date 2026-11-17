# NFC Foosball

Tap your phone on an NFC tag stuck to the foosball table, log in once, and you are in the match.
The app creates the match, starts it when everyone has joined, collects the score and updates
an Elo ranking.

For the full technical description (database, security, API, Elo derivation) see
[`docs/documentation.pdf`](docs/documentation.pdf), built from `docs/documentation.tex`.

## How it works

1. The tag stores a URL: `https://<your-domain>/t/<table-slug>`, for example `/t/main`.
2. The first tap opens the login page. After login or signup the player lands back on the table.
   Later taps go straight to the table, because the login is remembered by the browser.
3. If a match is waiting at the table, the player joins it. If nobody is playing, the player chooses
   **singles** (1 vs 1) or **doubles** (2 vs 2), and the others who tap join that match.
4. The match starts by itself when both teams are full.
5. At the end, any player of the match enters the score. Ratings are updated immediately.

Extra rules:

- A lobby that nobody joins for 30 minutes is deleted. A started match with no result after
  3 hours is cancelled. Players can also leave a lobby or cancel a running match.
- Elo is kept separately for singles and doubles. Everyone starts at 1200, base K = 32.
- Draws are allowed in casual matches. In a competition (tournament) matches can be worth more
  (a K multiplier) and draws can be switched off.

## Architecture

```
Phone browser (React app on Vercel)
   |-- Supabase Auth ........ sign up / sign in, issues a JWT
   '-- Edge Function match-api  (forwards the user's JWT)
            '-- PostgreSQL: tables, SQL functions, Row Level Security
```

- The browser never writes to match tables directly. Every action goes through `match-api`,
  which calls SQL functions that check `auth.uid()` and enforce the rules.
- The function uses the anon/publishable key and the user's JWT. No service-role key is used.

## Repository layout

```
nfc-foosball/
├── frontend/                  React + TypeScript + Vite
│   └── src/
│       ├── lib/               supabase.ts (client), api.ts (calls match-api)
│       ├── context/           AuthContext.tsx (who is logged in)
│       ├── components/        ProtectedRoute.tsx, AppHeader.tsx
│       └── pages/             LoginPage, TablePage, LeaderboardPage
├── supabase/
│   ├── functions/match-api/   the API (Edge Function)
│   ├── migrations/            database schema, in order
│   └── config.toml
├── firmware/                  reserved for a future ESP32 + PlatformIO device
├── docs/                      documentation.tex / documentation.pdf
└── README.md
```

Migrations, applied in this order:

| File | Content |
|---|---|
| `0001_initial_schema.sql` | tables, signup trigger, RLS, join/create/submit functions, leaderboard |
| `20261114120000_leave_cancel_cleanup.sql` | leave match, cancel match, cleanup of stale matches |
| `20261117100000_competitions_and_draws.sql` | competitions (K multiplier), draws |

## Run it locally

Requirements: Node.js, the [Supabase CLI](https://supabase.com/docs/guides/cli) and Docker in the root project!!

```bash
# 1. Start the local Supabase stack and apply all migrations
supabase start
supabase db reset

# 2. Serve the API
supabase functions serve

# 3. Frontend
cd frontend
npm install
```

Create `frontend/.env.local` with the values printed by `supabase status`:

```
VITE_SUPABASE_URL=http://127.0.0.1:54321
VITE_SUPABASE_PUBLISHABLE_KEY=<publishable (or anon) key>
```

```bash
npm run dev
```

Open <http://localhost:5173/t/main>. For local development, set `enable_confirmations = false`
under `[auth.email]` in `supabase/config.toml`, so signup works without email confirmation.

To try it from a phone on the same Wi-Fi: run `npm run dev -- --host` and use your computer's IP
in `VITE_SUPABASE_URL` instead of `127.0.0.1`.

## Deploy

### 1. Supabase (hosted project)

```bash
supabase login
supabase link --project-ref <YOUR_REF>   # the 20-character project reference
supabase db push
supabase functions deploy match-api
```

In the dashboard:

- **Authentication → Providers → Email:** turn off "Confirm email" for a friends-only app. The
  built-in email service is very limited, so confirmation emails will not arrive reliably.
  Use a custom SMTP provider if you want confirmation.
- **Authentication → URL Configuration:** set the Site URL to your production domain.
- If calls fail with `401 Invalid JWT` before reaching the code, add this to `supabase/config.toml`
  and redeploy (the function verifies the user itself):

  ```toml
  [functions.match-api]
  verify_jwt = false
  ```

- On the free plan a project is paused after about a week without activity; restore it from the
  dashboard.

### 2. Frontend (Vercel)

1. Push the repository to GitHub and import it in Vercel with **Root Directory = `frontend`**.
2. Add two environment variables for **Production**. Vite only exposes names starting with `VITE_`:

   | Name | Value |
   |---|---|
   | `VITE_SUPABASE_URL` | `https://<YOUR_REF>.supabase.co` |
   | `VITE_SUPABASE_PUBLISHABLE_KEY` | the hosted `sb_publishable_...` key |

3. `frontend/vercel.json` must contain the rewrite below, otherwise opening `/t/main` directly gives
   a 404:

   ```json
   { "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }] }
   ```

4. Redeploy after any change to the variables: they are baked in at build time.

Use only the **production domain** (for example `https://nfc-foosball.vercel.app`) for the tags and
for sharing. Preview and branch URLs (`...-git-main-...vercel.app`) are protected by Vercel login,
and each web address keeps its own login session.

## NFC tags

1. Open `https://<your-domain>/t/main` in a browser and check that it loads.
2. With a free app such as NFC Tools: Write → Add a record → URL/URI, enter the address, write it.
3. Test it by tapping the tag. When it works, lock the tag (this cannot be undone).

NTAG213 stickers are enough. NFC does not work through bare metal: use on-metal tags or a spacer.
iPhones from the XS onwards read tags in the background; on Android, NFC must be on. 34KB is the size of the link pasted in the NFC tag 

## Tables

A table is a row in `public.tables`. The slug is the part of the link, and it may contain only
lowercase letters, digits and dashes (2 to 40 characters). Run in the SQL editor:

```sql
insert into public.tables(name, slug) values ('Garage Table', 'garage');
```

Its tag is `https://<your-domain>/t/garage`. To close a table:
`update public.tables set is_active = false where slug = 'garage';`

## Competitions (tournament matches)

A competition scales the Elo K factor and can disable draws. Only the owner creates them, with SQL.
While a table is linked to a competition, every match created on it follows its rules:

```sql
-- create the event: matches are worth double, no draws
insert into public.competitions(name, k_multiplier, allows_draws)
values ('Friday Cup', 2, false);

-- start: link a table to it
update public.tables
set competition_id = (select id from public.competitions where name = 'Friday Cup')
where slug = 'main';

-- end: back to casual matches
update public.tables set competition_id = null where slug = 'main';
```

Do the switch when the table is idle. A match keeps the rules it was created with.

## Elo in short

For two teams with average ratings `R_A` and `R_B`:

```
E_A = 1 / (1 + 10^((R_B - R_A) / 400))          expected score of team A
S_A = 1 (A wins), 0.5 (draw), 0 (A loses)         actual score
delta_A = round(K * m * (S_A - E_A)),  delta_B = -delta_A
```

`K = 32` and `m` is the match multiplier (1 for casual matches). Every player of a team receives the
same change, and a rating never goes below 1. Example: two players rated 1200 play a casual match,
the winner gets +16 and the loser -16; in a x2 competition, +32 and -32.

## API

All requests are `POST /functions/v1/match-api` with `Authorization: Bearer <user JWT>` and a JSON
body `{ "action": "...", ... }`. Answers are `{ "data": ... }` or `{ "error": "...", "code": "..." }`.

| action | parameters | what it does |
|---|---|---|
| `join_table` | `table_slug`, `format` | join the match of the table, creating it if nobody is playing |
| `get_table_match` | `table_slug` | the table's open match, if visible to the caller |
| `get_match` | `match_id` | a match with its participants, table and competition |
| `leave_match` | `match_id` | leave an open match (deleted when empty) |
| `cancel_match` | `match_id` | cancel a match in progress, no rating change |
| `submit_result` | `match_id`, `team_a_score`, `team_b_score` | finish the match and update Elo |
| `get_leaderboard` | `format`, `limit` | ranking for singles or doubles |
| `create_match`, `join_match` | | lower-level actions used by `join_table` |

## Security notes

- Never put a service-role/secret key in the frontend, in a `VITE_` variable or in Git.
- Row Level Security is on for every table. Clients can read what the policies allow and cannot write
  directly; changes happen only through the SQL functions.
- Any participant's score is final: there is no confirmation step. The schema keeps a
  `result_confirmations` table for adding one later.
- The tag only identifies a table, not a player. Players always log in.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Failed to fetch" / "Load failed" | wrong or missing `VITE_SUPABASE_*` variables in the deployed build; redeploy |
| 404 on `/t/main` | missing `vercel.json` rewrite |
| Vercel login screen on another device | using a preview/branch URL instead of the production domain |
| "email rate limit exceeded" on signup | "Confirm email" is on in Supabase |
| "Database error saving new user" | display name not 2 to 32 characters, or already taken |
| Match does not start | doubles needs four players; or the hosted database lacks the latest migrations |
| `401 Invalid JWT` on API calls | set `verify_jwt = false` for `match-api` and redeploy |

## Roadmap

Direct-elimination brackets, a confirmation step for competition results, a "choose a table" page,
and an ESP32 device (the schema already reserves `table_devices`).
