-- NFC Foosball — initial schema
-- Apply once to a new Supabase project.

create extension if not exists pgcrypto;

do $$ begin
  create type public.match_format as enum ('singles', 'doubles');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.match_status as enum (
    'open', 'in_progress', 'pending_confirmation', 'completed', 'cancelled'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.team_side as enum ('A', 'B');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.confirmation_decision as enum ('accepted', 'rejected');
exception when duplicate_object then null; end $$;

-- Player profile is linked 1:1 to Supabase Auth.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null unique check (char_length(display_name) between 2 and 32),
  avatar_url text,
  created_at timestamptz not null default now()
);

create table if not exists public.tables (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique check (slug ~ '^[a-z0-9-]{2,40}$'),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  table_id uuid not null references public.tables(id),
  created_by uuid not null references public.profiles(id),
  format public.match_format not null,
  status public.match_status not null default 'open',
  team_a_score integer,
  team_b_score integer,
  proposed_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  result_proposed_at timestamptz,
  completed_at timestamptz,
  constraint scores_both_null_or_nonnegative check (
    (team_a_score is null and team_b_score is null)
    or (team_a_score is not null and team_b_score is not null
        and team_a_score >= 0 and team_b_score >= 0)
  ),
  constraint completed_has_result check (
    status <> 'completed'
    or (team_a_score is not null and team_b_score is not null
        and team_a_score <> team_b_score and completed_at is not null)
  )
);

create table if not exists public.match_players (
  match_id uuid not null references public.matches(id) on delete cascade,
  player_id uuid not null references public.profiles(id),
  team public.team_side not null,
  joined_at timestamptz not null default now(),
  primary key (match_id, player_id)
);

create index if not exists match_players_player_idx
  on public.match_players(player_id);

create index if not exists matches_created_at_idx
  on public.matches(created_at desc);

-- At most one not-yet-finished match per physical table.
create unique index if not exists one_active_match_per_table
  on public.matches(table_id)
  where status in ('open', 'in_progress', 'pending_confirmation');

create table if not exists public.player_ratings (
  player_id uuid not null references public.profiles(id) on delete cascade,
  format public.match_format not null,
  rating integer not null default 1200 check (rating > 0),
  games_played integer not null default 0 check (games_played >= 0),
  wins integer not null default 0 check (wins >= 0),
  losses integer not null default 0 check (losses >= 0),
  updated_at timestamptz not null default now(),
  primary key (player_id, format),
  check (wins + losses = games_played)
);

create table if not exists public.rating_history (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id),
  player_id uuid not null references public.profiles(id),
  format public.match_format not null,
  old_rating integer not null,
  new_rating integer not null,
  delta integer not null,
  created_at timestamptz not null default now(),
  unique (match_id, player_id)
);

create table if not exists public.result_confirmations (
  match_id uuid not null references public.matches(id) on delete cascade,
  player_id uuid not null references public.profiles(id),
  decision public.confirmation_decision not null,
  created_at timestamptz not null default now(),
  primary key (match_id, player_id)
);

create table if not exists public.match_events (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  actor_id uuid references public.profiles(id),
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Device credentials are hashed; provisioning/pairing is added in a later milestone.
create table if not exists public.table_devices (
  id uuid primary key default gen_random_uuid(),
  table_id uuid not null references public.tables(id),
  device_name text not null,
  credential_hash text not null unique,
  last_seen timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

-- Create a profile and both initial rating records after Auth registration.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  chosen_name text;
begin
  chosen_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(split_part(coalesce(new.email, 'player'), '@', 1), ''),
    'player'
  );

  -- Ensure uniqueness even if two users register with the same email prefix.
  if exists (select 1 from public.profiles p where p.display_name = chosen_name) then
    chosen_name := left(chosen_name, 24) || '-' || left(replace(new.id::text, '-', ''), 7);
  end if;

  insert into public.profiles(id, display_name)
  values (new.id, chosen_name)
  on conflict (id) do nothing;

  insert into public.player_ratings(player_id, format)
  values (new.id, 'singles'), (new.id, 'doubles')
  on conflict do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute function public.handle_new_user();

-- Helper: verify caller is a participant in the specified match.
create or replace function public.is_match_participant(p_match_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.match_players mp
    where mp.match_id = p_match_id and mp.player_id = auth.uid()
  );
$$;

-- Create a match. Creator is automatically assigned to Team A.
create or replace function public.create_match(
  p_table_slug text,
  p_format public.match_format
)
returns public.matches
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_table public.tables;
  v_match public.matches;
begin
  if v_user is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select * into v_table
  from public.tables
  where slug = p_table_slug and is_active = true;

  if not found then
    raise exception 'Table not found or inactive' using errcode = 'P0002';
  end if;

  insert into public.matches(table_id, created_by, format)
  values (v_table.id, v_user, p_format)
  returning * into v_match;

  insert into public.match_players(match_id, player_id, team)
  values (v_match.id, v_user, 'A');

  insert into public.match_events(match_id, actor_id, event_type, payload)
  values (v_match.id, v_user, 'match_created',
          jsonb_build_object('format', p_format, 'table_slug', p_table_slug));

  return v_match;
exception
  when unique_violation then
    raise exception 'This table already has an active match' using errcode = '23505';
end;
$$;

-- Join a match. Capacity is checked while the match row is locked.
create or replace function public.join_match(
  p_match_id uuid,
  p_team public.team_side
)
returns public.match_players
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_match public.matches;
  v_capacity integer;
  v_count integer;
  v_player public.match_players;
begin
  if v_user is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;

  if v_match.status <> 'open' then
    raise exception 'Match is not open for joining' using errcode = '55000';
  end if;

  if exists (
    select 1 from public.match_players
    where match_id = p_match_id and player_id = v_user
  ) then
    raise exception 'You already joined this match' using errcode = '23505';
  end if;

  v_capacity := case when v_match.format = 'singles' then 1 else 2 end;

  select count(*) into v_count
  from public.match_players
  where match_id = p_match_id and team = p_team;

  if v_count >= v_capacity then
    raise exception 'Selected team is full' using errcode = '23514';
  end if;

  insert into public.match_players(match_id, player_id, team)
  values (p_match_id, v_user, p_team)
  returning * into v_player;

  insert into public.match_events(match_id, actor_id, event_type, payload)
  values (p_match_id, v_user, 'player_joined',
          jsonb_build_object('team', p_team));

  return v_player;
end;
$$;

-- Start when both teams are full. Only creator can start.
create or replace function public.start_match(p_match_id uuid)
returns public.matches
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_match public.matches;
  v_capacity integer;
  v_a integer;
  v_b integer;
begin
  select * into v_match from public.matches
  where id = p_match_id for update;

  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;

  if v_user is null or v_match.created_by <> v_user then
    raise exception 'Only the creator can start this match' using errcode = '42501';
  end if;

  if v_match.status <> 'open' then
    raise exception 'Match is not open' using errcode = '55000';
  end if;

  v_capacity := case when v_match.format = 'singles' then 1 else 2 end;

  select count(*) filter (where team = 'A'),
         count(*) filter (where team = 'B')
  into v_a, v_b
  from public.match_players
  where match_id = p_match_id;

  if v_a <> v_capacity or v_b <> v_capacity then
    raise exception 'Both teams must be full before starting' using errcode = '23514';
  end if;

  update public.matches
  set status = 'in_progress', started_at = now()
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events(match_id, actor_id, event_type)
  values (p_match_id, v_user, 'match_started');

  return v_match;
end;
$$;

-- Propose a score. No Elo changes until every participant accepts.
create or replace function public.submit_match_result(
  p_match_id uuid,
  p_team_a_score integer,
  p_team_b_score integer
)
returns public.matches
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_match public.matches;
begin
  if v_user is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if p_team_a_score is null or p_team_b_score is null
     or p_team_a_score < 0 or p_team_b_score < 0
     or p_team_a_score = p_team_b_score then
    raise exception 'Scores must be non-negative and cannot be tied' using errcode = '22023';
  end if;

  select * into v_match from public.matches
  where id = p_match_id for update;

  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;

  if not public.is_match_participant(p_match_id) then
    raise exception 'Only participants can submit a result' using errcode = '42501';
  end if;

  if v_match.status <> 'in_progress' then
    raise exception 'Match is not in progress' using errcode = '55000';
  end if;

  update public.matches
  set team_a_score = p_team_a_score,
      team_b_score = p_team_b_score,
      proposed_by = v_user,
      result_proposed_at = now(),
      status = 'pending_confirmation'
  where id = p_match_id
  returning * into v_match;

  delete from public.result_confirmations where match_id = p_match_id;

  insert into public.match_events(match_id, actor_id, event_type, payload)
  values (p_match_id, v_user, 'result_proposed',
          jsonb_build_object('team_a_score', p_team_a_score,
                             'team_b_score', p_team_b_score));

  return v_match;
end;
$$;

-- Confirm or reject. On unanimous acceptance, update Elo exactly once.
create or replace function public.confirm_match_result(
  p_match_id uuid,
  p_accepted boolean
)
returns public.matches
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_match public.matches;
  v_player_count integer;
  v_confirmed_count integer;
  v_avg_a numeric;
  v_avg_b numeric;
  v_expected_a numeric;
  v_delta_a integer;
  v_delta_b integer;
  v_k constant integer := 32;
  r record;
  v_old integer;
  v_new integer;
  v_won boolean;
begin
  if v_user is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select * into v_match from public.matches
  where id = p_match_id for update;

  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;

  if v_match.status <> 'pending_confirmation' then
    raise exception 'No result is awaiting confirmation' using errcode = '55000';
  end if;

  if not public.is_match_participant(p_match_id) then
    raise exception 'Only participants can confirm' using errcode = '42501';
  end if;

  insert into public.result_confirmations(match_id, player_id, decision)
  values (
    p_match_id,
    v_user,
    case when p_accepted then 'accepted'::public.confirmation_decision
         else 'rejected'::public.confirmation_decision end
  )
  on conflict (match_id, player_id)
  do update set decision = excluded.decision, created_at = now();

  insert into public.match_events(match_id, actor_id, event_type, payload)
  values (p_match_id, v_user,
          case when p_accepted then 'result_accepted' else 'result_rejected' end,
          '{}'::jsonb);

  if not p_accepted then
    update public.matches
    set status = 'in_progress',
        team_a_score = null,
        team_b_score = null,
        proposed_by = null,
        result_proposed_at = null
    where id = p_match_id
    returning * into v_match;

    delete from public.result_confirmations where match_id = p_match_id;

    insert into public.match_events(match_id, actor_id, event_type)
    values (p_match_id, v_user, 'result_disputed');

    return v_match;
  end if;

  select count(*) into v_player_count
  from public.match_players where match_id = p_match_id;

  select count(*) into v_confirmed_count
  from public.result_confirmations
  where match_id = p_match_id and decision = 'accepted';

  if v_confirmed_count <> v_player_count then
    return v_match;
  end if;

  -- Lock rating rows in deterministic player-id order to reduce deadlock risk.
  perform 1
  from public.player_ratings pr
  join public.match_players mp on mp.player_id = pr.player_id
  where mp.match_id = p_match_id and pr.format = v_match.format
  order by pr.player_id
  for update of pr;

  select avg(pr.rating) into v_avg_a
  from public.player_ratings pr
  join public.match_players mp on mp.player_id = pr.player_id
  where mp.match_id = p_match_id and mp.team = 'A'
    and pr.format = v_match.format;

  select avg(pr.rating) into v_avg_b
  from public.player_ratings pr
  join public.match_players mp on mp.player_id = pr.player_id
  where mp.match_id = p_match_id and mp.team = 'B'
    and pr.format = v_match.format;

  v_expected_a := 1.0 / (1.0 + power(10.0, (v_avg_b - v_avg_a) / 400.0));

  if v_match.team_a_score > v_match.team_b_score then
    v_delta_a := round(v_k * (1.0 - v_expected_a))::integer;
  else
    v_delta_a := round(v_k * (0.0 - v_expected_a))::integer;
  end if;
  v_delta_b := -v_delta_a;

  for r in
    select mp.player_id, mp.team
    from public.match_players mp
    where mp.match_id = p_match_id
    order by mp.player_id
  loop
    select rating into v_old
    from public.player_ratings
    where player_id = r.player_id and format = v_match.format
    for update;

    v_won := (r.team = 'A' and v_match.team_a_score > v_match.team_b_score)
          or (r.team = 'B' and v_match.team_b_score > v_match.team_a_score);

    if r.team = 'A' then
      v_new := greatest(1, v_old + v_delta_a);
    else
      v_new := greatest(1, v_old + v_delta_b);
    end if;

    update public.player_ratings
    set rating = v_new,
        games_played = games_played + 1,
        wins = wins + case when v_won then 1 else 0 end,
        losses = losses + case when v_won then 0 else 1 end,
        updated_at = now()
    where player_id = r.player_id and format = v_match.format;

    insert into public.rating_history(
      match_id, player_id, format, old_rating, new_rating, delta
    ) values (
      p_match_id, r.player_id, v_match.format, v_old, v_new, v_new - v_old
    );
  end loop;

  update public.matches
  set status = 'completed', completed_at = now()
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events(match_id, actor_id, event_type, payload)
  values (p_match_id, v_user, 'match_completed',
          jsonb_build_object('elo_delta_team_a', v_delta_a,
                             'elo_delta_team_b', v_delta_b));

  return v_match;
end;
$$;

-- Public-ish leaderboard data: authenticated users may read rankings.
create or replace view public.leaderboard
with (security_invoker = true)
as
select
  pr.player_id,
  p.display_name,
  pr.format,
  pr.rating,
  pr.games_played,
  pr.wins,
  pr.losses,
  case when pr.games_played = 0 then 0
       else round(100.0 * pr.wins / pr.games_played, 1) end as win_percentage
from public.player_ratings pr
join public.profiles p on p.id = pr.player_id;

-- RLS
alter table public.profiles enable row level security;
alter table public.tables enable row level security;
alter table public.matches enable row level security;
alter table public.match_players enable row level security;
alter table public.player_ratings enable row level security;
alter table public.rating_history enable row level security;
alter table public.result_confirmations enable row level security;
alter table public.match_events enable row level security;
alter table public.table_devices enable row level security;

-- Profiles: authenticated users can view profiles; only update own profile.
create policy "profiles readable by authenticated users"
on public.profiles for select to authenticated using (true);

create policy "players update own profile"
on public.profiles for update to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- Tables are discoverable by authenticated users; no client writes.
create policy "active tables readable"
on public.tables for select to authenticated using (is_active = true);

-- Matches: participants/creator can read; open matches can be discovered to join.
create policy "matches readable by authenticated users"
on public.matches for select to authenticated
using (
  status = 'open'
  or created_by = auth.uid()
  or public.is_match_participant(id)
);

-- Participants can see participant list for open matches or matches they joined.
create policy "match players readable"
on public.match_players for select to authenticated
using (
  exists (
    select 1 from public.matches m
    where m.id = match_id
      and (m.status = 'open' or public.is_match_participant(m.id))
  )
);

-- Ratings and leaderboard are visible to authenticated users.
create policy "ratings readable"
on public.player_ratings for select to authenticated using (true);

create policy "rating history readable"
on public.rating_history for select to authenticated using (true);

-- Confirmation and audit details are visible to match participants.
create policy "confirmations readable by participants"
on public.result_confirmations for select to authenticated
using (public.is_match_participant(match_id));

create policy "events readable by participants"
on public.match_events for select to authenticated
using (public.is_match_participant(match_id));

-- No policies for table_devices: client access is intentionally denied.

-- Grant read access only where RLS policies further restrict rows.
grant usage on schema public to authenticated;
grant select on public.profiles, public.tables, public.matches,
  public.match_players, public.player_ratings, public.rating_history,
  public.result_confirmations, public.match_events to authenticated;
grant select on public.leaderboard to authenticated;

-- Explicitly remove direct writes from client roles.
revoke insert, update, delete on public.profiles, public.tables, public.matches,
  public.match_players, public.player_ratings, public.rating_history,
  public.result_confirmations, public.match_events, public.table_devices
from anon, authenticated;

-- RPC execution: authenticated users only.
revoke all on function public.create_match(text, public.match_format) from public;
revoke all on function public.join_match(uuid, public.team_side) from public;
revoke all on function public.start_match(uuid) from public;
revoke all on function public.submit_match_result(uuid, integer, integer) from public;
revoke all on function public.confirm_match_result(uuid, boolean) from public;

grant execute on function public.create_match(text, public.match_format) to authenticated;
grant execute on function public.join_match(uuid, public.team_side) to authenticated;
grant execute on function public.start_match(uuid) to authenticated;
grant execute on function public.submit_match_result(uuid, integer, integer) to authenticated;
grant execute on function public.confirm_match_result(uuid, boolean) to authenticated;

-- Seed the initial physical table.
insert into public.tables(name, slug)
values ('Main Table', 'main')
on conflict (slug) do nothing;
