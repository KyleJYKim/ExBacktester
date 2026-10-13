defmodule ExBacktester.Bench.Client do
  @moduledoc """
  One closed-loop "terminal" for the Broker benchmark.

  Each client loops until a deadline:

    Think for Z -> Broker.order/4 (call, wait for reply) -> repeat

  In queueing terms:

    * the `Process.sleep/1` is the **think time Z**: a delay station.
      The client is not competing for anything while it sleeps,
      so many client can "think" at once (an infinite-server station);
    * the `Broker.order/4` call is a **visit** to the central station.
      The time from sending to receiving the reply is the **response time R**
      for that visit, which includes anu time spent waiting in the Broker's
      mailbox behind other clients.

  Because a client sends its next request only after the previous reply,
  the number of clients N is fixed for the whole run: a **closed system**.

  Orders alternate buy/sell of one share so the account never runs out of cash or position;
  every order takes the same (successful) code path, so the service time stays homogeneous.
  """

  alias ExBacktester.Broker

  @doc """
  Run the loop. Only cycles that *start* after `measure_from` (a monotonic timestamp in ns) are recorded,
  so the warm-up period is excluded.

  returns `%{completed: n, sum_r_ns: total response time, sum_z_ns: total measured think time}`.
  """
  def run(account, ticker, z_ms, measure_from, deadline) do
    loop(account, ticker, z_ms, measure_from, deadline, :buy, %{completed: 0, sum_r_ns: 0, sum_z_ns: 0})
  end

  defp loop(account, ticker, z_ms, measure_from, deadline, side, acc) do
    z0 = now()

    if z0 >= deadline do
      acc
    else
      # Think time: a delay, not CPU work.
      if z_ms > 0, do: Process.sleep(z_ms)

      t0 = now()
      # Response time
      {:ok, _fill} = Broker.order(account, side, ticker, 1)
      t1 = now()

      acc =
        if z0 >= measure_from and t1 <= deadline do
          %{acc | completed: acc.completed + 1, sum_r_ns: acc.sum_r_ns + (t1 - t0), sum_z_ns: acc.sum_z_ns + (t0 - z0)}
        else
          acc
        end

      loop(account, ticker, z_ms, measure_from, deadline, flip(side), acc)
    end
  end

  defp flip(:buy), do: :sell
  defp flip(:sell), do: :buy

  defp now, do: System.monotonic_time(:nanosecond)
end
