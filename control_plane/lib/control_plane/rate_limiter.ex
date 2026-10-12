defmodule ControlPlane.RateLimiter do
  @moduledoc """
  A small fixed-window rate limiter backed by a single public ETS table.

  `hit/3` records one request against `key` and reports whether the caller has
  exceeded `max` requests within the current `window_ms`-wide window. Counters are
  keyed by `{key, window}` where `window = system_time / window_ms`, so each window
  has its own counter and an old window's count never bleeds into the next.

  The GenServer owns the table and periodically sweeps counters whose window has
  ended so memory stays bounded; the hot path (`hit/3`) is a lock-free
  `:ets.update_counter/4`, not a GenServer call, so it adds no serialization point.
  """
  use GenServer

  @table :rate_limiter
  @sweep_interval_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Clears every rate-limit counter. Intended for test isolation — the table is a
  single global keyed by client IP, so without a per-test reset counters from one
  test bleed into the next (every test request comes from 127.0.0.1) and later
  tests spuriously hit `429`.
  """
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Records a hit for `key` in the current window and returns `:ok` if the caller is
  within `max`, or `{:error, :rate_limited}` once they exceed it.
  """
  def hit(key, max, window_ms) do
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    # Atomically bump the count at position 2; seed a fresh row carrying the end
    # of its window at position 3 (left untouched by later increments) for sweeping.
    #
    # Het einde van het venster, niet het moment van aanmaken. De veger gooide
    # eerst alles weg dat ouder was dan tien minuten, wat het venster ook was:
    # "drie per uur" begon zo elke tien minuten opnieuw, en een dagteller hield
    # nooit langer dan tien minuten stand. Met het venstereinde in de rij weet de
    # veger per teller wanneer die echt niet meer mee kan tellen.
    window_end = (window + 1) * window_ms
    count = :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0, window_end})

    if count > max, do: {:error, :rate_limited}, else: :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    # Delete counters whose window (ending at position 3) is over.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
