defmodule ExBacktester.Bench.Model do
  @moduledoc """
  Analytical predictions for a closed interactive system: N terminals with think time Z, in front of K queueing stations with service demands D_i.
  Everything here is a pure function, so every formula can be checked by hand and tested against the course's (software performance) worked examples.

  For the Broker benchmark there is a single queueing station (the Broker), so `demands = [d_b]`.
  The functions accept a list so teh same code works for the multi-station examples in the notes, and for step 3, where the Broker gets split into several stations.

  Units are whatever passed in, as long as they are consistent (all seconds, or all microseconds).
  """

  @doc """
  Asymptotic bounds (notes, Theorem 3.3).
  These need no assumptions about service-time distributions or scheduling; they come from the operational laws alone.
    X(N) <= min( N / (D + Z), 1 / D_b )
    R(N) >= max( D, N * D_b - Z )

  where D = sum of all D_i (the time one job needs if it never waits) and D_b = max D_i (the bottleneck station's demand).

  * `N / (D + Z)`: light load. Each terminal completes at most one cycle per (D + Z), since that is a cycle with zero queueing.
    N terminals: N times that.
  * `1 / D_b`: heavy load. The bottleneck is busy at most 100% of the time (U_b = X * D_b <= 1),
    so X <= 1 / D_b no matter how many terminals.
  * `R >= N * D_b - Z`: rearranged interactive response time law, R = N / X - Z,
    with X at its ceiling 1 / D_b.
  """
  def bounds(n, demands, z) do
    d = Enum.sum(demands)
    d_b = Enum.max(demands)

    %{x_upper: min(n / (d + z), 1 / d_b), r_lower: max(d, n * d_b - z)}
  end

  @doc """
  The knee, where the two throughput asymptotes cross (notes, eq. 3.7):
    N / (D + Z) = 1 / D_b   =>  N* = (D + Z) / D_b
  Below N*, adding a terminal adds throughput almost for free.
  Above N*, the bottleneck is saturated: an extra terminal adds no throughput,
  only D_b of extra response time for everyone (the slope of N * D_b - Z).
  """
  def knee(demands, z), do: (Enum.sum(demands) + z) / Enum.max(demands)

  @doc """
  Exact Mean Value Analysis for a single-class closed network of single-server FCFS queueing stations plus one delay (think) station.
  Returns one map per population n = 1..N.

  The recursion, for n = 1, 2, ..., N, starting from Q_i(0) = 0:
    R_i(n) = D_i * (1 + Q_i(n - 1))   arrival theorem
    X(n)   = n / (Z + sum_i R_i(n))   interactive response time law
    Q_i(n) = X(n) * R_i(n)            Little's law, per station
  The first line is the whole trick. By the arrival theorem, a job arriving at station `i` in a network of `n` jobs finds, on average, the queue length of the same network with n - 1 jobs (itself removed).
  It must wait for all of them to be served, then be served itself: (Q_i(n - 1) + 1) * D_i.

  The think station has no such term. Its "response time" is always Z, because it has as many servers as there are terminals: nobody ever waits to think.
  That is what "delay station" or "infinite-server station" means, and why Z enters X(n) as a constant while the R_i grow with `n`.

  Exact under product-form assumptions (exponential service at FCFS stations).
  Real systems violate them; the bounds above do not depend on them, so a measurement can fall outside the MVA curve but never outside the bounds.
  """
  def mva(n_max, demands, z) do
    zeros = Enum.map(demands, fn _ -> 0.0 end)

    {rows, _q} =
      Enum.map_reduce(1..n_max, zeros, fn n, q_prev ->
        rs = Enum.zip_with(demands, q_prev, fn d, q -> d * (1 + q) end)
        r = Enum.sum(rs)
        x = n / (r + z)
        q = Enum.map(rs, &(x * &1))

        {%{n: n, x: x, r: r, q: q, u: Enum.map(demands, &(x * &1))}, q}
      end)

    rows
  end
end
