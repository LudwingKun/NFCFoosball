-- Lobby controls and cleanup of matches that are never played.
--  * leave_match: a player leaves an OPEN match; the match is deleted when nobody is left.
--  * cancel_match: a participant cancels a match that is IN PROGRESS (kept as 'cancelled', no Elo change).
--  * cleanup_stale_matches: removes old lobbies and cancels abandoned matches.
--    It is called by the API every time someone taps the table, so no scheduler is needed.

create or replace function public.leave_match(p_match_id uuid)
returns boolean  -- true when the match was deleted because it became empty
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_match public.matches;
  v_remaining integer;
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
    raise exception 'Only a match that has not started can be left' using errcode = '55000';
  end if;

  delete from public.match_players
  where match_id = p_match_id and player_id = v_user;

  if not found then
    raise exception 'You are not in this match' using errcode = '42501';
  end if;

  select count(*) into v_remaining
  from public.match_players
  where match_id = p_match_id;

  if v_remaining = 0 then
    -- Nobody left: remove the match (its events are removed by cascade).
    delete from public.matches where id = p_match_id;
    return true;
  end if;

  insert into public.match_events(match_id, actor_id, event_type)
  values (p_match_id, v_user, 'player_left');

  return false;
end;
$$;

create or replace function public.cancel_match(p_match_id uuid)
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

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if not found then
    raise exception 'Match not found' using errcode = 'P0002';
  end if;

  if not public.is_match_participant(p_match_id) then
    raise exception 'Only participants can cancel a match' using errcode = '42501';
  end if;

  if v_match.status <> 'in_progress' then
    raise exception 'Only a match in progress can be cancelled' using errcode = '55000';
  end if;

  update public.matches
  set status = 'cancelled'
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events(match_id, actor_id, event_type)
  values (p_match_id, v_user, 'match_cancelled');

  return v_match;
end;
$$;

create or replace function public.cleanup_stale_matches()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_lobby_timeout constant interval := interval '30 minutes';  -- no new player for this long
  c_play_timeout  constant interval := interval '3 hours';     -- started but no result
begin
  -- Lobbies that never filled up are deleted.
  delete from public.matches m
  where m.status = 'open'
    and coalesce(
          (select max(mp.joined_at) from public.match_players mp where mp.match_id = m.id),
          m.created_at
        ) < now() - c_lobby_timeout;

  -- Matches that started but never got a result are cancelled (kept for history).
  update public.matches
  set status = 'cancelled'
  where status = 'in_progress'
    and started_at < now() - c_play_timeout;
end;
$$;

revoke all on function public.leave_match(uuid) from public;
revoke all on function public.cancel_match(uuid) from public;
revoke all on function public.cleanup_stale_matches() from public;
grant execute on function public.leave_match(uuid) to authenticated;
grant execute on function public.cancel_match(uuid) to authenticated;
grant execute on function public.cleanup_stale_matches() to authenticated;
