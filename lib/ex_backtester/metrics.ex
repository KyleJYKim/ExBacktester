defmodule ExBacktester.Metrics do
  @moduledoc """
  The three metrics, computed from an equity curve (a list of total account values, one per bar, oldest first).
  Exactly three -- no more (v0.1 rule).

  This module is pure: equity curve in, numbers out, no processes.
  That is deliberate, because this is the code most likely to be "silently" wrong -- a metric bug does not crash, it just prints a plausible-looking wrong number.
  Pure functions are the easy kind to test exhaustively, so keep everything here total and side-effect-free.
  """

  @trading_days_per_year 252

  @type curve :: [float()]

  @doc """
  Total return as a fraction: (last - first) / first.
  A curve with fewer than two points has no return; returns 0.0.
  """
  @spec total_return(curve()) :: float()
  def total_return([]), do: 0.0
  def total_return([_only]), do: 0.0

  def total_return(curve) do
    first = List.first(curve)
    last = List.last(curve)
    if first == 0.0, do: 0.0, else: (last - first) / first
  end

  @doc """
  Daily simple returns from an equity curve: for each adjacent pair (prev, cur), (cur - prev) / prev.
  Length is one less than the curve.
  """
  @spec daily_returns(curve()) :: curve()
  def daily_returns(curve) when length(curve) < 2, do: []

  def daily_returns(curve) do
    curve
    |> Enum.zip(tl(curve))
    |> Enum.map(fn {prev, cur} ->
      if prev == 0.0, do: 0.0, else: (cur - prev) / prev
    end)
  end

  @doc """
  Annualized Sharpe ratio (risk-free rate assumed 0):
      mean (daily_returns) / stddev(daily_returns) * sqrt(252)
  Uses the population standard deviation.
  If there is no variation (or fewer than two returns),
  Sharpe is undefined and reported as 0.0 rather than raising or returning infinity -- a flat curve is not a good Sharpe, it is simply not a meaningful one.
  """
  @spec sharpe(curve()) :: float()
  def sharpe(curve) do
    returns = daily_returns(curve)

    case returns do
      [] -> 0.0
      [_only] -> 0.0
      _ ->
        m = mean(returns)
        sd = stddev(returns, m)
        if sd == 0.0, do: 0.0, else: m / sd * :math.sqrt(@trading_days_per_year)
    end
  end

  @doc """
  Maximum drawdown as a fraction in [0, 1]: the largest peak-to-trough decline in the equity curve.

  Walk the curve tracking the running peak; at each point the drawdown is (peak - value) / peak.
  The maximum of those is the answer. A curve that only ever rises has drawdown 0.0.
  """
  @spec max_drawdown(curve()) :: float()
  def max_drawdown([]), do: 0.0
  def max_drawdown([_only]), do: 0.0

  def max_drawdown([head | tail]) do
    {_peak, mdd} = Enum.reduce(tail, {head, 0.0}, fn value, {peak, mdd} ->
      peak = max(peak, value)
      dd = if peak == 0.0, do: 0.0, else: (peak - value) / peak
      {peak, max(mdd, dd)}
    end)

    mdd
  end

  # Helpers

  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp stddev(xs, m) do
    variance = Enum.reduce(xs, 0.0, fn x, acc -> acc + (x - m) * (x - m) end) / length(xs)
    :math.sqrt(variance)
  end
end
