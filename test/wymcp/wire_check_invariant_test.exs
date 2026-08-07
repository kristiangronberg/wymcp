defmodule Wymcp.WireCheckInvariantTest do
  @moduledoc """
  One sweep block per verb in `@verbs`, plus a dialect-pin block per verb in
  `@pinned` — the `Wymcp.VersionMatrixTest` pattern, so a failing run names
  the verb and the block in its `describe` heading.

  **The sweep** covers every verb in `@verbs`, this module's closed world.
  Under each of the three wire checks it asserts `Wymcp.Router` answers
  either that check's rejection or nothing at all — 404 with no
  `content-type` header. The two disjuncts are mutually exclusive on the
  wire: a rejection is sent through `Wymcp.Response`, which always sets
  `content-type`, and the fallthrough `match(_)` sets none. This is the
  floor an unwired route fails — a route added to `Wymcp.Router` without
  `with_wire_checks/2` answers its own 400, its own 200, or raises, and all
  three of that verb's sweep tests say so. The sweep was demonstrated to
  catch exactly that: a temporary `patch("/", do: handle_get(conn))` in
  `Wymcp.Router` fails all three PATCH cells.

  **The floor has one hole**, and it is the price of discriminating on the
  response rather than on which route produced it: a route that answers a
  bare 404 with no `content-type` is wearing `match(_)`'s own wire shape, so
  `nothing_served?/1` reads it as nothing-served and all three of its cells
  pass unwired. Closing that needs a marker `match(_)` sets in
  `conn.private` for the predicate to read — a `lib/` change, which is why
  it is not done here.

  **The dialect pin** covers `@pinned`, the verbs wymcp serves, and adds the
  rejection's full shape: status, the `WWW-Authenticate` challenge, and the
  route's error dialect. Pinning stays opt-in — a newly wired route is swept
  whether or not its verb joins `@pinned`. What it forgoes is everything
  past the sweep's status check: for the auth and origin cells `rejection?/2`
  looks at the status alone, so an unpinned verb's `WWW-Authenticate`
  challenge and exact rejection message go unasserted along with its dialect.

  No request here carries an `Mcp-Session-Id` header: a wire-check answer
  arriving instead of the routes' missing-header 400 is what proves the
  checks run before the session-header read. The origin and auth checks
  discriminate by status (403, 401); the singleton-header check answers a
  400 of its own — the same status the routes answer for a missing
  `Mcp-Session-Id` header — so it discriminates on the message text instead.
  That is why it duplicates `MCP-Protocol-Version` rather than
  `Mcp-Session-Id`, leaving the no-session-header premise intact.

  `:frob` is the one `@verbs` entry no `Plug.Router` *verb macro* can
  declare. It stays in the nothing-served branch and pins the fallthrough's
  own design decision (`Wymcp.Router`'s moduledoc) instead of leaving it
  implied by the verbs that merely happen to have no route today. The
  exception to hold in mind is `match/3`'s `:via` option, which declares a
  route for any method atom — `:frob` included. A route reached only that
  way has no cell here at all, so `@verbs` is this module's closed world,
  not `Plug.Router`'s.

  ## Exemptions

  `@check_exempt_verbs` is the one way out, one (verb × check) cell at a
  time: `verb: [check: "reason"]` exempts that verb from the named check
  only, and every check the entry does not name stays swept. A listed cell
  is **asserted, not skipped** — under that check's scenario the verb must
  answer neither the rejection nor nothing-served, so the route must exist
  *and* the check must genuinely not have run. That keeps a stale entry
  loud: an entry whose route never landed, or that was later wired with the
  named check after all, fails. Both halves were demonstrated before this
  module shipped: temporary entries on a wired verb (the rejection arrives)
  and on a verb with no route (nothing is served) each failed their cell.

  The list ships empty, so the first entry is a deliberate, reviewable edit
  — and it is also an edit to `Wymcp.Router`'s moduledoc, whose "Every
  non-fallthrough route … runs all three wire checks" stops being literally
  true the moment that entry lands.

  ## Known residual — HEAD's singleton-header cell

  `Plug.Test` drops HEAD response bodies but not their headers, which is why
  "nothing served" discriminates on `content-type` rather than on body text.
  The singleton-header check is the one whose rejection must be recognised
  by its message, and the message is exactly what HEAD loses: a `head "/"`
  wired with all three checks would answer 400 with `content-type` set and
  an empty body — neither disjunct — so that one cell would fail a correct
  implementation. Nothing answers HEAD today and both consumers rewrite HEAD
  to GET upstream via `Plug.Head`, so the cell currently passes through
  nothing-served. Whoever wires `head "/"` resolves it there: either move
  this module's HEAD requests off `Plug.Test`, or accept a mechanical
  exception for that one cell — the kind of exception the sweep otherwise
  deliberately has none of, which is why it belongs in that reviewer's
  hands rather than being pre-authorized here.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  defmodule FailAuth do
    @behaviour Wymcp.Auth

    @impl Wymcp.Auth
    def authenticate(_conn), do: {:error, "Unauthorized"}
  end

  # This module's closed world: the seven verbs Plug.Router has a route
  # macro for, plus :frob. A verb reachable only through match/3's :via
  # option is outside it — see the moduledoc. Plug.Test upcases whatever
  # method it is handed, so conn(:frob, "/") builds a real FROB request
  # that reaches match(_).
  @verbs [:get, :head, :post, :put, :patch, :delete, :options, :frob]

  # The verbs wymcp serves — a subset of @verbs, so a pinned verb is swept
  # as well as pinned. The redundancy is the point: a wired verb left out of
  # this list loses its dialect assertion, never its sweep.
  @pinned [:post, :get, :delete]

  # The three wire checks in the order Wymcp.Router runs them, each with the
  # label its test names read with.
  @checks [origin: "origin", auth: "auth", singleton_header: "singleton-header"]

  # verb: [check: "reason"] — exempt from the named checks only; every
  # unnamed check is swept normally. Empty at ship, so assert_cell/4's
  # second clause compiles but never runs until the first entry lands.
  #
  #   options: [auth: "CORS preflight carries no Authorization header,
  #             so it cannot be authenticated"]
  @check_exempt_verbs []

  @disallowed_origin "http://evil.example"
  @duplicate_message "Duplicated MCP-Protocol-Version header. Send exactly one MCP-Protocol-Version header."

  for verb <- @verbs do
    exemptions = Keyword.get(@check_exempt_verbs, verb, [])

    describe "#{verb |> Atom.to_string() |> String.upcase()} / — wire-check sweep" do
      for {check, label} <- @checks do
        case Keyword.fetch(exemptions, check) do
          :error ->
            test "the #{label} check rejects it, or nothing is served" do
              assert_cell(unquote(verb), unquote(check), unquote(label), nil)
            end

          {:ok, reason} ->
            test "the #{label} check is exempt — #{reason}" do
              assert_cell(unquote(verb), unquote(check), unquote(label), unquote(reason))
            end
        end
      end
    end
  end

  for verb <- @pinned do
    describe "#{verb |> Atom.to_string() |> String.upcase()} / — rejection dialect" do
      test "an unauthenticated request answers 401" do
        conn = call_router(unquote(verb), :auth)

        assert conn.status == 401
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
        assert_route_dialect(unquote(verb), conn, "Unauthorized")
      end

      test "a disallowed-Origin request answers 403" do
        conn = call_router(unquote(verb), :origin)

        assert conn.status == 403
        assert_route_dialect(unquote(verb), conn, "Origin not allowed: #{@disallowed_origin}")
      end

      @tag doc: """
           The discriminator here is the message, not the status: this
           rejection is itself a 400, the same status the routes answer for
           a missing Mcp-Session-Id header. Full rationale in this module's
           moduledoc.
           """
      test "a request duplicating a reject-class singleton header answers 400" do
        conn = call_router(unquote(verb), :singleton_header)

        assert conn.status == 400
        assert_route_dialect(unquote(verb), conn, @duplicate_message)
      end
    end
  end

  # -- Helpers --

  defp assert_cell(verb, check, label, nil) do
    conn = call_router(verb, check)

    assert rejection?(check, conn) or nothing_served?(conn),
           cell_report(verb, label, conn, "the check's rejection, or nothing served")
  end

  defp assert_cell(verb, check, label, reason) when is_binary(reason) do
    conn = call_router(verb, check)

    refute rejection?(check, conn),
           cell_report(verb, label, conn, "no rejection — exempt: #{reason}")

    refute nothing_served?(conn),
           cell_report(verb, label, conn, "a served route — exempt: #{reason}")
  end

  # The label, not the check atom: the failure message and the test names
  # must name the check the same way.
  defp cell_report(verb, label, conn, expected) do
    """
    #{verb |> Atom.to_string() |> String.upcase()} / under the #{label} check.
    Expected #{expected}.

      status:       #{inspect(conn.status)}
      content-type: #{inspect(get_resp_header(conn, "content-type"))}
      body:         #{inspect(conn.resp_body)}
    """
  end

  # Each check's scenario: the Wymcp.Router options that arm it and the
  # request headers that trip it. Sweep and pin both call through here, so
  # the two blocks cannot drift on what a check's scenario is.
  defp scenario(:origin) do
    {[origin: ["http://allowed.example"]], [{"origin", @disallowed_origin}]}
  end

  defp scenario(:auth), do: {[auth: FailAuth], []}

  defp scenario(:singleton_header) do
    header = {"mcp-protocol-version", "2025-11-25"}
    {[], [header, header]}
  end

  defp call_router(verb, check) do
    {extra_opts, headers} = scenario(check)

    request(verb, Wymcp.Router.init([tools: []] ++ extra_opts), headers)
  end

  # POST runs its wire checks inside Plugs.Pipeline, where the auth check
  # sits after body parsing — the body must be valid JSON for the request
  # to reach it.
  # prepend_req_headers/2, not merge_req_headers/2: merge replaces by key
  # (List.keystore/4), so it cannot express the duplicated header the
  # singleton-header check exists to reject.
  defp request(:post, opts, extra_headers) do
    conn(:post, "/", JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}))
    |> put_req_header("content-type", "application/json")
    |> prepend_req_headers(extra_headers)
    |> Wymcp.Router.call(opts)
  end

  # Every other verb, including the ones no route serves.
  defp request(method, opts, extra_headers) do
    conn(method, "/")
    |> prepend_req_headers(extra_headers)
    |> Wymcp.Router.call(opts)
  end

  defp rejection?(:origin, conn), do: conn.status == 403

  defp rejection?(:auth, conn), do: conn.status == 401

  defp rejection?(:singleton_header, conn) do
    conn.status == 400 and is_binary(conn.resp_body) and
      String.contains?(conn.resp_body, @duplicate_message)
  end

  defp nothing_served?(conn) do
    conn.status == 404 and get_resp_header(conn, "content-type") == []
  end

  # A wire-check rejection speaks the error dialect of the route it ran on —
  # pinned per verb, so a new @pinned entry cannot pass while answering the
  # wrong dialect. A pinned verb with no clause here raises
  # FunctionClauseError; that is the intended forcing function, not a gap.
  defp assert_route_dialect(:post, conn, message) do
    body = JSON.decode!(conn.resp_body)
    assert body["error"]["code"] == -32600
    assert body["error"]["data"]["error"] == message
  end

  defp assert_route_dialect(method, conn, message) when method in [:get, :delete] do
    assert JSON.decode!(conn.resp_body) == %{"error" => message}
  end
end
