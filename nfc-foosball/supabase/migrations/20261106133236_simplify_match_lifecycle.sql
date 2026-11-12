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

  if p_team_a_score > p_team_b_score then
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
        losses = losses + case when v_won then 0 else 1 end,
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
    jsonb_build_object('elo_delta_team_a', v_delta_a, 'elo_delta_team_b', v_delta_b)
  );

  return v_match;
end;
$$;

revoke all on function public.join_match(uuid, public.team_side) from public;
revoke all on function public.submit_match_result(uuid, integer, integer) from public;
grant execute on function public.join_match(uuid, public.team_side) to authenticated;
grant execute on function public.submit_match_result(uuid, integer, integer) to authenticated;
