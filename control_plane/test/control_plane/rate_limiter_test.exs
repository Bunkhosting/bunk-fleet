defmodule ControlPlane.RateLimiterTest do
  # The RateLimiter's ETS table is owned by the app-supervised GenServer, which is
  # running in the test env. Each test uses a unique key so counters don't collide.
  # async: false — ConnCase's per-test RateLimiter.reset() clears the shared ETS
  # table, which would wipe this test's in-flight counters; running in the sync
  # phase keeps it isolated from those resets.
  use ExUnit.Case, async: false

  alias ControlPlane.RateLimiter

  defp unique_key, do: "test-#{System.unique_integer([:positive])}"

  test "allows up to max hits in a window, then rate-limits" do
    key = unique_key()

    # max = 3: the first three are allowed, the fourth is limited.
    assert RateLimiter.hit(key, 3, 60_000) == :ok
    assert RateLimiter.hit(key, 3, 60_000) == :ok
    assert RateLimiter.hit(key, 3, 60_000) == :ok
    assert RateLimiter.hit(key, 3, 60_000) == {:error, :rate_limited}
    assert RateLimiter.hit(key, 3, 60_000) == {:error, :rate_limited}
  end

  test "counts each key independently" do
    a = unique_key()
    b = unique_key()

    assert RateLimiter.hit(a, 1, 60_000) == :ok
    assert RateLimiter.hit(a, 1, 60_000) == {:error, :rate_limited}
    # b has its own budget, untouched by a.
    assert RateLimiter.hit(b, 1, 60_000) == :ok
  end

  test "a new window resets the counter" do
    key = unique_key()

    # A 1ms window means consecutive calls almost always land in fresh windows, so
    # the limit effectively never trips across distinct windows.
    assert RateLimiter.hit(key, 1, 1) == :ok
    Process.sleep(2)
    assert RateLimiter.hit(key, 1, 1) == :ok
  end

  test "de veger ruimt op wat afgelopen is en laat een lopende dag staan" do
    # De veger keek eerst naar de leeftijd van een teller, niet naar zijn venster:
    # na tien minuten ging alles weg. Een dagteller begon zo steeds opnieuw, en
    # "drie per uur" werd drie per tien minuten.
    kort = unique_key()
    dag = unique_key()

    assert RateLimiter.hit(kort, 1, 1) == :ok
    assert RateLimiter.hit(dag, 1, :timer.hours(24)) == :ok
    Process.sleep(2)

    send(RateLimiter, :sweep)
    # Een synchrone aanroep na de send: pas als die terugkomt, is :sweep verwerkt.
    _ = :sys.get_state(RateLimiter)

    sleutels = Enum.map(:ets.tab2list(:rate_limiter), fn {{sleutel, _}, _, _} -> sleutel end)
    refute kort in sleutels
    assert RateLimiter.hit(dag, 1, :timer.hours(24)) == {:error, :rate_limited}
  end
end
