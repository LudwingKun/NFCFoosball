-- Team choice from the NFC tag and a table menu.
--  * create_match gets an optional team, so the first player of a match can start on side B.
--    The old two-argument function is replaced (the default keeps old calls working).
--  * table_overview(): one row per active table with the state of its match, for the table menu.

drop function if exists public.create_match(text, public.match_format);

create function public.create_match(
  p_table_slug text,
  p_format public.match_format,
  p_team public.team_side default 'A'
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
  values (v_match.id, v_user, p_team);

  insert into public.match_events(match_id, actor_id, event_type, payload)
  values (v_match.id, v_user, 'match_created',
          jsonb_build_object('format', p_format, 'table_slug', p_table_slug, 'team', p_team,
                             'competition_id', v_comp.id,
                             'k_multiplier', v_match.k_multiplier));

  return v_match;
exception
  when unique_violation then
    raise exception 'This table already has an active match' using errcode = '23505';
end;
$$;

revoke all on function public.create_match(text, public.match_format, public.team_side) from public;
grant execute on function public.create_match(text, public.match_format, public.team_side) to authenticated;

-- Overview of the active tables and of the match running on each (if any).
-- SECURITY DEFINER on purpose: players need to see that a table is busy even when
-- row level security hides that match from them. Only counts and statuses are returned.
create or replace function public.table_overview()
returns table (
  slug text,
  name text,
  competition_name text,
  match_status public.match_status,
  format public.match_format,
  players integer,
  capacity integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    t.slug,
    t.name,
    c.name,
    m.status,
    m.format,
    (select count(*)::integer from public.match_players mp where mp.match_id = m.id),
    case m.format when 'singles' then 2 when 'doubles' then 4 end
  from public.tables t
  left join public.competitions c on c.id = t.competition_id and c.is_active
  left join public.matches m on m.table_id = t.id and m.status in ('open', 'in_progress')
  where t.is_active
  order by t.name;
$$;

revoke all on function public.table_overview() from public;
grant execute on function public.table_overview() to authenticated;
