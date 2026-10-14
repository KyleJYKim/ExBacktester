defmodule ExBacktester.Bench do
  @moduledoc """
  Performance experiments on the Broker, treated as a queueing station.

  This module measures; it does not change how backtests run. The backtest
  itself stays synchronous and deterministic. Here we deliberately load the
  Broker from many concurrent clients to study it as a single-server FCFS queue
  (its mailbox is the queue, its process is the server).

  Notation:

    * N - number of clients (multiprogramming level), fixed per run
    * Z - mean think time per cycle
    * R - mean response time of one Broker call
    * X - system throughput, completed orders per second
    * S - Broker service time per visit
    * V - visits to the Broker per cycle (here 1)
    * D - service demand, D = V * S
    * U - Broker utilization, U = X * D (bottleneck law)
  """

  alias ExBacktester.{Bar, Broker}

  @ticker "BENCH"

  # Step 1a: pure service time

  @doc """
  Pure service time S: run `Broker.handle_call/3` as a plain function on a local state, with no processes and no messages.
  This isolates the work the Broker does per order (the money arithmetic and map updates).

  Returns the mean in microseconds.
  """
  def service_time(iterations \\1_000_000) do
    {:ok, state} = Broker.init(:ok)
    from = {self(), make_ref()}
    {:reply, :ok, state} = Broker.handle_call({:open_account, :s, [record_trades: false]}, from, state)
    {:reply, :ok, state} = Broker.handle_call({:mark, bar(1.0)}, from, state)

    # Warm up so the JIT / caches are in a steady state before timing.
    _ = loop_service(state, from, 50_000)

    t0 = now()
    _ = loop_service(state, from, iterations)
    (now() - t0) / iterations / 1_000
  end

  defp loop_service(state, _from, 0), do: state

  defp loop_service(state, from, n) do
    side = if rem(n, 2) == 0, do: :buy, else: :sell
    {:reply, {:ok, _}, state} = Broker.handle_call({:order, :s, side, @ticker, 1}, from, state)
    loop_service(state, from, n - 1)
  end

  # Step 1b and later: closed-loop runs

  @doc """
  Run N concurrent closed-loop clients against the live Broker.

  Options:
    * `:z_ms`       - think time in ms (default 1)
    * `:warmup_ms`  - discarded warm-up period (default 500)
    * `:measure_ms` - measured period (default 3000)

    Returns a map with the measured X, R, Z and the mean Broker mailbox length.
  """
  def run(n, opts \\ []) do
    z_ms = Keyword.get(opts, :z_ms, 1)
    warmup_ms = Keyword.get(opts, :warmup_ms, 500)
    measure_ms = Keyword.get(opts, :measure_ms, 3_000)

    accounts = for i <- 1..n, do: :"bench_#{n}_#{i}"
    Enum.each(accounts, &Broker.open_account(&1, record_trades: false))
    :ok = Broker.mark(bar(1.0))

    start = now()
    measure_from = start + ms(warmup_ms)
    deadline = measure_from + ms(measure_ms)

    sampler = Task.async(fn -> sample_queue(measure_from, deadline) end)

    stats =
      accounts |> Enum.map(fn acct ->
        Task.async(fn ->
          ExBacktester.Bench.Client.run(acct, @ticker, z_ms, measure_from, deadline)
        end)
      end)
      |> Task.await_many(:infinity)

    queue_samples = Task.await(sampler, :infinity)

    completed = Enum.sum(Enum.map(stats, & &1.completed))
    sum_r = Enum.sum(Enum.map(stats, & &1.sum_r_ns))
    sum_z = Enum.sum(Enum.map(stats, & &1.sum_z_ns))

    %{
      n: n,
      z_set_ms: z_ms,
      completed: completed,
      x_per_s: completed / (measure_ms / 1_000),
      r_us: safe_div(sum_r, completed) / 1_000,
      z_us: safe_div(sum_z, completed) / 1_000,
      mailbox_mean: mean(queue_samples)
    }
  end

  # Sample the Broker's mailbox length every ~1 ms during the measured window.
  # Sleeping (not busy-waiting) keeps the sampler from stealing CPU
  # from the Broker it is observing. This is the number of requests *waiting*,
  # not counting the one currently in service.
  defp sample_queue(from, deadline) do
    pid = Process.whereis(Broker)
    wait_until(from)
    do_sample(pid, deadline, [])
  end

  defp do_sample(pid, deadline, acc) do
    if now() >= deadline do
      acc
    else
      {:message_queue_len, len} = Process.info(pid, :message_queue_len)
      Process.sleep(1)
      do_sample(pid, deadline, [len | acc])
    end
  end

  defp wait_until(t) do
    if now() < t do
      Process.sleep(1)
      wait_until(t)
    end
  end

  # helpers

  defp bar(close) do
    %Bar{
      ticker: @ticker,
      date: ~D[2024-01-02],
      open: close,
      high: close,
      low: close,
      close: close,
      volume: 1
    }
  end

  defp now, do: System.monotonic_time(:nanosecond)
  defp ms(x), do: x * 1_000_000
  defp safe_div(_a, 0), do: 0.0
  defp safe_div(a, b), do: a / b
  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)
end
