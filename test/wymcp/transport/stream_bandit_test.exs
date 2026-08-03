defmodule Wymcp.Transport.StreamBanditTest do
  @moduledoc """
  Regression gate for the stream's process-ownership invariant. Bandit —
  unlike Plug.Test — raises ("Adapter functions must be called by stream
  owner") when any process other than the request's own writes chunks, so
  these tests run the GET stream over a real HTTP server and a real TCP
  socket. Only the adapter-dependent behaviors live here — the priming
  write, a push arriving over TCP, a replaced stream handing its committed
  chunked conn back to the adapter mid-stream, and a push to a client that
  has gone away; framing, resumption, and the write-failure branches
  themselves are covered under Plug.Test in stream_test.exs.

  Bandit, Req, and ThousandIsland are test-only dependencies. Each test
  starts its own listener on an ephemeral loopback port
  (ip: {127, 0, 0, 1}, port: 0) via start_supervised!/1 — the suite's
  first supervised fixture, used so ExUnit shuts the listener down
  deterministically — which keeps the module async: true. The bind
  address is pinned rather than left to default: these fixtures mount the
  router with no :auth or :origin configured, so every wire check passes
  (Noop auth), and the wildcard bind a missing :ip produces would put a
  live, unauthenticated MCP session on every interface for the test's
  duration. Sessions are created directly through
  Wymcp.Session.start_session/1: the HTTP handshake is not what this gate
  covers, and the sessions live in the same BEAM as the listener.

  Req streams a response into the mailbox of the process that called
  Req.get! (into: :self), and Req.parse_message/2 answers :unknown for a
  message belonging to a different response. One process therefore reads
  exactly one response: the replacement test, which keeps two open at
  once, runs the first response's whole protocol — open, read, read to
  done — inside its own Task. (A single reader would consume the other
  response's messages and drop them, losing the first stream's :done for
  good.) Because each reader owns one response, an :unknown message is
  something that is not Req's at all and is skipped. read_until/3
  accumulates parsed chunks because SSE events may split across TCP
  packets, and a message can carry the last data and :done together, so
  data is always folded in before an end is reported.
  """

  use ExUnit.Case, async: true

  alias Wymcp.Session
  alias Wymcp.Testing

  # An order of magnitude under the plain-push bound (the pusher's own
  # GenServer.call default, 5 000 ms) and three orders above a loopback
  # round trip: it separates "answered by the loop" from "waited out the
  # caller's timeout" without being a wall-clock race.
  @prompt_push_ms 500

  test "the priming event reaches the client over a real socket" do
    port = start_bandit()
    {_session_pid, session_id} = start_session()

    response = open_stream(port, session_id)

    assert response.status == 200
    assert read_until(response, "id: evt-1\ndata: \n\n")

    Session.terminate_session(session_id)
  end

  test "a Session.push arrives over real TCP" do
    port = start_bandit()
    {session_pid, session_id} = start_session()

    response = open_stream(port, session_id)
    read_until(response, "id: evt-1\ndata: \n\n")

    assert :ok =
             Session.push(session_pid, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/message"
             })

    body = read_until(response, ~s("method":"notifications/message"))
    assert body =~ "id: evt-2\n"

    Session.terminate_session(session_id)
  end

  @tag doc: """
       A replaced stream returns its committed chunked conn to Bandit
       mid-stream — process-reuse and connection semantics Plug.Test
       structurally cannot exercise. The first response must end cleanly
       (Req parses :done; no crash, no truncation error) while the second
       stream serves its own priming event.
       """
  test "a second GET replaces the first stream over a real socket" do
    port = start_bandit()
    {_session_pid, session_id} = start_session()
    test_pid = self()

    # The first response is opened and read entirely inside this Task, so
    # its Finch messages never share a mailbox with the second response's.
    first =
      Task.async(fn ->
        response = open_stream(port, session_id)
        send(test_pid, {:first_primed, read_until(response, "id: evt-1\ndata: \n\n")})
        read_done(response)
      end)

    # 3 s, deliberately longer than the reader's own 2 s budget: if the
    # priming bytes never arrive, the Task's flunk surfaces with its own
    # message instead of this assert timing out first on a bare tuple.
    assert_receive {:first_primed, _bytes}, 3_000

    second = open_stream(port, session_id)
    assert read_until(second, "id: evt-1\ndata: \n\n")

    assert Task.await(first, 3_000) == :done

    Session.terminate_session(session_id)
  end

  @tag doc: """
       The disconnect over a real socket. A failed chunk write is the
       whole signal that the client is gone: the loop runs in Bandit's
       connection process, which survives the stream and can go on
       serving the connection, so the session's stream monitor need never
       fire. Two things must hold and only a real socket shows them —
       every push answers promptly (a stale registration makes a push
       wait out its caller's full call timeout against a mailbox nobody
       drains), and the registration is cleared. The branch logic itself
       is unit-tested with stand-in adapters in stream_test.exs; what
       this proves is that the real adapter reports the failure at all.
       """
  test "a push after the client disconnects answers promptly and clears the registration" do
    port = start_bandit()
    {session_pid, session_id} = start_session()

    response = open_stream(port, session_id)
    read_until(response, "id: evt-1\ndata: \n\n")

    :ok = Req.cancel_async_response(response)

    assert push_until_gone(session_pid, 10)
    assert wait_for_no_stream(session_pid)

    Session.terminate_session(session_id)
  end

  defp start_bandit do
    server =
      start_supervised!(
        {Bandit,
         plug: {Wymcp.Router, [tools: []]},
         ip: {127, 0, 0, 1},
         port: 0,
         http_options: [compress: false]}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp start_session do
    {:ok, pid, session_id} = Session.start_session(Testing.build_session_opts())
    {pid, session_id}
  end

  defp open_stream(port, session_id) do
    Req.get!("http://127.0.0.1:#{port}/",
      headers: [{"mcp-session-id", session_id}],
      into: :self
    )
  end

  # A cancelled Req response closes with a FIN, and a FIN does not fail
  # the next write — the peer answers RST a round trip later — so an
  # early push can still report :ok. Retry until the stream reports
  # itself gone; what must hold on *every* attempt is the latency.
  # {:error, :no_stream} is a legitimate ending too: if the connection
  # process happens to die outright, the session's monitor clears the
  # registration before any write is attempted. A push that wedges past
  # the caller's call timeout answers
  # {:error, :timeout} — also a failure of this test, reported by the
  # flunk below.
  defp push_until_gone(_session_pid, 0) do
    flunk("the stream never reported the disconnect over 10 pushes")
  end

  defp push_until_gone(session_pid, attempts) do
    message = %{"jsonrpc" => "2.0", "method" => "notifications/message"}
    {elapsed_us, result} = :timer.tc(fn -> Session.push(session_pid, message) end)

    assert elapsed_us < @prompt_push_ms * 1_000,
           "push answered #{inspect(result)} after #{div(elapsed_us, 1_000)}ms"

    case result do
      :ok -> push_until_gone(session_pid, attempts - 1)
      {:error, :disconnected} -> true
      {:error, :no_stream} -> true
      other -> flunk("unexpected push reply after a client disconnect: #{inspect(other)}")
    end
  end

  defp wait_for_no_stream(session_pid, remaining_ms \\ 2_000) do
    case Session.get_state(session_pid).stream_pid do
      nil ->
        true

      _pid when remaining_ms > 0 ->
        Process.sleep(10)
        wait_for_no_stream(session_pid, remaining_ms - 10)

      _pid ->
        flunk("the stream registration was not cleared within 2s")
    end
  end

  defp read_until(response, pattern, acc \\ "") do
    if String.contains?(acc, pattern) do
      acc
    else
      {status, data} = next_message(response)
      keep_reading(response, pattern, acc <> data, status)
    end
  end

  # The end of the stream is not a timeout: report it as what it is, with
  # the bytes that did arrive, instead of blocking for another 2s.
  defp keep_reading(_response, pattern, acc, :done) do
    if String.contains?(acc, pattern) do
      acc
    else
      flunk("the stream ended before #{inspect(pattern)} arrived; read: #{inspect(acc)}")
    end
  end

  defp keep_reading(response, pattern, acc, :more) do
    read_until(response, pattern, acc)
  end

  defp read_done(response) do
    case next_message(response) do
      {:done, _data} -> :done
      {:more, _data} -> read_done(response)
    end
  end

  # Req.parse_message/2 answers {:ok, chunks} | {:error, reason} |
  # :unknown — the error clause is easy to miss and would be a
  # CaseClauseError exactly when a test is already failing.
  defp next_message(response) do
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, chunks} -> {chunk_status(chunks), chunk_data(chunks)}
          {:error, reason} -> flunk("the stream errored: #{inspect(reason)}")
          :unknown -> {:more, ""}
        end
    after
      2_000 -> flunk("SSE bytes did not arrive within 2s")
    end
  end

  defp chunk_status(chunks), do: if(:done in chunks, do: :done, else: :more)

  defp chunk_data(chunks), do: for({:data, data} <- chunks, into: "", do: data)
end
