import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function badRequest(message: string) {
  return jsonResponse({ error: message }, 400);
}
type Participant = { player_id: string; team: string };

const TEAM_SIZE: Record<string, number> = { singles: 1, doubles: 2 };

// The active match of a table (open or in progress), with its participants.
// RLS decides what the caller can see: open matches, and matches they are in.
// deno-lint-ignore no-explicit-any
async function findActiveMatch(supabase: any, slug: string) {
  return await supabase
    .from("matches")
    .select(
      "id, status, format, tables!inner(slug), participants:match_players(player_id, team)",
    )
    .eq("tables.slug", slug)
    .in("status", ["open", "in_progress"])
    .limit(1)
    .maybeSingle();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Use POST" }, 405);
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return jsonResponse({ error: "Missing bearer token" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

  if (!supabaseUrl || !anonKey) {
    return jsonResponse({ error: "Server configuration is incomplete" }, 500);
  }

  // The caller's JWT is forwarded so auth.uid() is available inside Postgres.
  // No service-role key is used by this function.
  const supabase = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError || !userData.user) {
    return jsonResponse({ error: "Invalid or expired access token" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return badRequest("Request body must be valid JSON");
  }

  const action = body.action;
  let result: unknown;
  let error: { message: string; code?: string } | null = null;

  switch (action) {
    case "create_match": {
      const tableSlug = body.table_slug;
      const format = body.format;
      if (typeof tableSlug !== "string" ||
        !["singles", "doubles"].includes(String(format))) {
        return badRequest("table_slug and format (singles|doubles) are required");
      }
      ({ data: result, error } = await supabase.rpc("create_match", {
        p_table_slug: tableSlug,
        p_format: format,
      }));
      break;
    }

    case "join_match": {
      const matchId = body.match_id;
      const team = body.team;
      if (typeof matchId !== "string" || !["A", "B"].includes(String(team))) {
        return badRequest("match_id and team (A|B) are required");
      }
      ({ data: result, error } = await supabase.rpc("join_match", {
        p_match_id: matchId,
        p_team: team,
      }));
      break;
    }
    case "get_table_match": {
      if (typeof body.table_slug !== "string") {
        return badRequest("table_slug is required");
      }
      ({ data: result, error } = await findActiveMatch(supabase, body.table_slug));
      break;
    }
    case "join_table": {
      const slug = body.table_slug;
      const format = body.format ?? "doubles";
      if (typeof slug !== "string" || !["singles", "doubles"].includes(String(format))) {
        return badRequest("table_slug and format (singles|doubles) are required");
      }
      const me = userData.user.id;

      // Housekeeping: drop lobbies nobody joined for 30 min and cancel matches
      // that were started but never finished. Errors here must not block the join.
      await supabase.rpc("cleanup_stale_matches");

      const found = await findActiveMatch(supabase, slug);
      if (found.error) {
        error = found.error;
        break;
      }
      const active = found.data;

      if (!active) {
        // Nobody is playing: open a new match (the creator becomes Team A).
        // If another match is running that I cannot see, this fails with 23505 -> 409.
        ({ error } = await supabase.rpc("create_match", {
          p_table_slug: slug,
          p_format: format,
        }));
      } else if (!active.participants.some((p: Participant) => p.player_id === me)) {
        if (active.status !== "open") {
          return jsonResponse({ error: "A match is already in progress on this table" }, 409);
        }
        // Put the new player in the emptier team (Team A on a tie).
        const size = TEAM_SIZE[active.format];
        const count = (t: string) =>
          active.participants.filter((p: Participant) => p.team === t).length;
        const a = count("A");
        const b = count("B");
        const team = b >= size ? "A" : a >= size ? "B" : a <= b ? "A" : "B";

        ({ error } = await supabase.rpc("join_match", {
          p_match_id: active.id,
          p_team: team,
        }));
      }
      // else: I am already in this match, nothing to do.

      if (error) break;

      const refreshed = await findActiveMatch(supabase, slug);
      result = refreshed.data;
      error = refreshed.error;
      break;
    }

    case "leave_match": {
      if (typeof body.match_id !== "string") {
        return badRequest("match_id is required");
      }
      // Returns true when the match was deleted because nobody was left in it.
      ({ data: result, error } = await supabase.rpc("leave_match", {
        p_match_id: body.match_id,
      }));
      break;
    }

    case "cancel_match": {
      if (typeof body.match_id !== "string") {
        return badRequest("match_id is required");
      }
      ({ data: result, error } = await supabase.rpc("cancel_match", {
        p_match_id: body.match_id,
      }));
      break;
    }

    case "submit_result": {
      if (typeof body.match_id !== "string" ||
        !Number.isInteger(body.team_a_score) ||
        !Number.isInteger(body.team_b_score)) {
        return badRequest("match_id and integer team scores are required");
      }
      ({ data: result, error } = await supabase.rpc("submit_match_result", {
        p_match_id: body.match_id,
        p_team_a_score: body.team_a_score,
        p_team_b_score: body.team_b_score,
      }));
      break;
    }
    /* TODO: maybe re-enable later
        case "confirm_result": {
          if (typeof body.match_id !== "string" ||
              typeof body.accepted !== "boolean") {
            return badRequest("match_id and boolean accepted are required");
          }
          ({ data: result, error } = await supabase.rpc("confirm_match_result", {
            p_match_id: body.match_id,
            p_accepted: body.accepted,
          }));
          break;
        }
    **/
    case "get_match": {
      if (typeof body.match_id !== "string") {
        return badRequest("match_id is required");
      }
      ({ data: result, error } = await supabase
        .from("matches")
        .select(`
      *,
      table:tables(*),
      competition:competitions(name),
      participants:match_players(
        player_id,
        team,
        joined_at,
        profile:profiles(display_name, avatar_url)
      )
    `)
        .eq("id", body.match_id)
        .single());
      break;
    }

    case "get_leaderboard": {
      const format = body.format ?? "singles";
      const limit = body.limit ?? 20;

      if (!["singles", "doubles"].includes(String(format)) ||
        !Number.isInteger(limit) || Number(limit) < 1 || Number(limit) > 100) {
        return badRequest("format must be singles|doubles and limit must be 1..100");
      }

      const { data, error: leaderboardError } = await supabase
        .from("leaderboard")
        .select("*")
        .eq("format", format)
        .order("rating", { ascending: false })
        .limit(Number(limit));

      result = data;
      error = leaderboardError;
      break;
    }

    default:
      return badRequest("Unknown action");
  }

  if (error) {
    // Avoid returning internal SQL details to the client.
    const message = error.message || "Database operation failed";
    const statusByCode: Record<string, number> = {
      "42501": 403,
      "P0002": 404,
      "PGRST116": 404, // .single() found no row (e.g. the match was deleted)
      "23505": 409,
      "55000": 409,
      "23514": 409,
    };
    const status = statusByCode[error.code ?? ""] ?? 400;

    return jsonResponse({ error: message, code: error.code ?? null }, status);
  }

  return jsonResponse({ data: result });
});
