-- Match types (competitions) and draws.
--  * competitions: an event (e.g. a tournament) with a K-factor multiplier and a rule on draws.
--    Only the project owner creates them (SQL editor / migration); players cannot.
--  * tables.competition_id: while set, every match created on that table belongs to the competition.
--  * matches.k_multiplier / allows_draws: copied at creation, so old results never change.
--  * Draws: a draw counts as half a win in Elo (S = 0.5) and is stored in player_ratings.draws.

-- ---------------------------------------------------------------- competitions
create table if not exists public.competitions (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 2 and 60),
  k_multiplier numeric(4,2) not null default 2
    check (k_multiplier > 0 and k_multiplier <= 10),
  allows_draws boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.competitions enable row level security;

create policy "competitions readable"
on public.competitions for select to authenticated using (true);

grant select on public.competitions to authenticated;
revoke insert, update, delete on public.competitions from anon, authenticated;

alter table public.tables
  add column if not exists competition_id uuid
  references public.competitions(id) on delete set null;

alter table public.matches
  add column if not exists competition_id uuid
    references public.competitions(id) on delete set null,
  add column if not exists k_multiplier numeric(4,2) not null default 1
    check (k_multiplier > 0),
  add column if not exists allows_draws boolean not null default true;

-- A completed match needs different scores, unless draws are allowed for it.
alter table public.matches drop constraint if exists completed_has_result;
alter table public.matches add constraint completed_has_result check (
  status <> 'completed'
  or (team_a_score is not null and team_b_score is not null
      and (team_a_score <> team_b_score or allows_draws)
      and completed_at is not null)
);

-- ---------------------------------------------------------------- draws in ratings
alter table public.player_ratings
  add column if not exists draws integer not null default 0 check (draws >= 0);

do $$
declare
  c record;
begin
  for c in
    select conname
    from pg_constraint
    where conrelid = 'public.player_ratings'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%wins + losses%'
  loop
    execute format('alter table public.player_ratings drop constraint %I', c.conname);
  end loop;
end;
$$;

alter table public.player_ratings
  add constraint player_ratings_record_check
  check (wins + losses + draws = games_played);

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
       else round(100.0 * pr.wins / pr.games_played, 1) end as win_percentage,
  pr.draws
from public.player_ratings pr
join public.profiles p on p.id = pr.player_id;

-- ---------------------------------------------------------------- create_match
-- Same as before, but the match copies the competition rules of its table.
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
  v_comp public.competitions;
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

  -- No active competition on this table: a casual match (x1, draws allowed).
  select * into v_comp
  from public.competitions
  where id = v_table.competition_id and is_active = true;

  insert into public.matches(
    table_id, created_by, format, competition_id, k_multiplier, allows_draws
  )
  values (
    v_table.id, v_user, p_format, v_comp.id,
    coalesce(v_comp.k_multiplier, 1), coalesce(v_comp.allows_draws, true)
  )
  returning * into v_match;

  insert into public.match_players(match_id, player_id, team)
  values (v_match.id, v_user, 'A');

  insert into public.match_events(match_id, actor_id, event_type, payload)
  values (v_match.id, v_user, 'match_created',
          jsonb_build_object('format', p_format, 'table_slug', p_table_slug,
                             'competition_id', v_comp.id,
                             'k_multiplier', v_match.k_multiplier));

  return v_match;
exception
  when unique_violation then
    raise exception 'This table already has an active match' using errcode = '23505';
end;
$$;

-- ---------------------------------------------------------------- submit_match_result
-- Elo with draws and the match K multiplier:
--   E_A = 1 / (1 + 10^((R_B - R_A) / 400))     (R = average rating of the team)
--   S_A = 1 (A wins), 0.5 (draw), 0 (A loses)
--   delta_A = round(K * m * (S_A - E_A)),      delta_B = -delta_A
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
  v_avg_a numeric;
  v_avg_b numeric;
  v_expected_a numeric;
  v_delta_a integer;
  v_delta_b integer;
  c_base_k constant integer := 32;
  v_k numeric;
  v_s_a numeric;
  r record;
  v_old integer;
  v_new integer;
  v_won boolean;
  v_drew boolean;
begin
  if v_user is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if p_team_a_score is null or p_team_b_score is null
     or p_team_a_score < 0 or p_team_b_score < 0 then
    raise exception 'Scores must be non-negative numbers' using errcode = '22023';
  end if;

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;

  if not public.is_match_participant(p_match_id) then
    raise exception 'Only participants can submit a result'
      using errcode = '42501';
  end if;

  if v_match.status <> 'in_progress' then
    raise exception 'Match is not in progress' using errcode = '55000';
  end if;

  if p_team_a_score = p_team_b_score and not v_match.allows_draws then
    raise exception 'A draw is not allowed in this match' using errcode = '22023';
  end if;

  -- Base K is scaled by the match multiplier saved when the match was created.
  v_k := c_base_k * v_match.k_multiplier;

  -- This status transition and all Elo writes commit or roll back together.
  update public.matches
  set team_a_score = p_team_a_score,
      team_b_score = p_team_b_score,
      proposed_by = v_user,
      result_proposed_at = now(),
      status = 'completed',
      completed_at = now()
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events(match_id, actor_id, event_type, payload)
  values (
    p_match_id, v_user, 'result_submitted',
    jsonb_build_object('team_a_score', p_team_a_score, 'team_b_score', p_team_b_score)
  );

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

  if v_avg_a is null or v_avg_b is null then
    raise exception 'Both teams must have all players before submitting a result'
      using errcode = '23514';
  end if;

  v_expected_a := 1.0 / (1.0 + power(10.0, (v_avg_b - v_avg_a) / 400.0));

  v_s_a := case
             when p_team_a_score > p_team_b_score then 1.0
             when p_team_a_score < p_team_b_score then 0.0
             else 0.5
           end;

  v_delta_a := round(v_k * (v_s_a - v_expected_a))::integer;
  v_delta_b := -v_delta_a;
  v_drew := (p_team_a_score = p_team_b_score);

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

    v_won :=
      (r.team = 'A' and p_team_a_score > p_team_b_score)
      or (r.team = 'B' and p_team_b_score > p_team_a_score);

    if r.team = 'A' then
      v_new := greatest(1, v_old + v_delta_a);
    else
      v_new := greatest(1, v_old + v_delta_b);
    end if;

    update public.player_ratings
    set rating = v_new,
        games_played = games_played + 1,
        wins = wins + case when v_won then 1 else 0 end,
        losses = losses + case when v_won or v_drew then 0 else 1 end,
        draws = draws + case when v_drew then 1 else 0 end,
        updated_at = now()
    where player_id = r.player_id and format = v_match.format;

    insert into public.rating_history(
      match_id, player_id, format, old_rating, new_rating, delta
    )
    values (p_match_id, r.player_id, v_match.format, v_old, v_new, v_new - v_old);
  end loop;

  insert into public.match_events(match_id, actor_id, event_type, payload)
  values (
    p_match_id, v_user, 'match_completed',
    jsonb_build_object('elo_delta_team_a', v_delta_a, 'elo_delta_team_b', v_delta_b,
                       'k_multiplier', v_match.k_multiplier, 'draw', v_drew)
  );

  return v_match;
end;
$$;

-- create or replace keeps the existing grants; repeated here to be explicit.
revoke all on function public.create_match(text, public.match_format) from public;
revoke all on function public.submit_match_result(uuid, integer, integer) from public;
grant execute on function public.create_match(text, public.match_format) to authenticated;
grant execute on function public.submit_match_result(uuid, integer, integer) to authenticated;
