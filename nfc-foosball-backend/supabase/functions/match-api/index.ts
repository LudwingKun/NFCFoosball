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

    case "start_match": {
      if (typeof body.match_id !== "string") return badRequest("match_id is required");
      ({ data: result, error } = await supabase.rpc("start_match", {
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

    case "get_match": {
      if (typeof body.match_id !== "string") return badRequest("match_id is required");

      const { data: match, error: matchError } = await supabase
        .from("matches")
        .select(`
          *,
          table:tables(name, slug),
          participants:match_players(
            player_id, team, joined_at,
            profile:profiles(display_name)
          ),
          confirmations:result_confirmations(player_id, decision, created_at)
        `)
        .eq("id", body.match_id)
        .maybeSingle();

      result = match;
      error = matchError;
      if (!match && !matchError) {
        return jsonResponse({ error: "Match not found or not accessible" }, 404);
      }
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
    const status = error.code === "42501" ? 403
      : error.code === "P0002" ? 404
      : error.code === "23505" ? 409
      : error.code === "55000" ? 409
      : error.code === "23514" ? 409
      : 400;

    return jsonResponse({ error: message, code: error.code ?? null }, status);
  }

  return jsonResponse({ data: result });
});
