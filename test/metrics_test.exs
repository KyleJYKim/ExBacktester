defmodule ExBacktester.MetricsTest do
  @moduledoc """
  Metrics are pure and high-stakes (a wrong number here silently poisons every reported result),
  so each is tested against a value computed by hand, plus the degenerate cases that tend to divide by zero.
  """

  use ExUnit.Case, async: true

  alias ExBacktester.Metrics

  describe "total_return/1" do
    test "empty and single-point curves have zero return" do
      assert Metrics.total_return([]) == 0.0
      assert Metrics.total_return([100.0]) == 0.0
    end

    test "computes (last - first) / first" do
      # 100 -> 110 is +10%
      assert_in_delta Metrics.total_return([100.0, 105.0, 110.0]), 0.10, 1.0e-9
    end

    test "handles a loss" do
      # 100 -> 80 is -20%
      assert_in_delta Metrics.total_return([100.0, 90.0, 80.0]), -0.20, 1.0e-9
    end
  end

  describe "daily_returns/1" do
    test "is empty for curves shorter than two points" do
      assert Metrics.daily_returns([]) == []
      assert Metrics.daily_returns([100.0]) == []
    end

    test "has length one less than the curve" do
      assert length(Metrics.daily_returns([1.0, 2.0, 3.0, 4.0])) == 3
    end

    test "computes each adjacent percentage change" do
      # 100 -> 110 = +0.10 ; 110 -> 99 = -0.10
      rs = Metrics.daily_returns([100.0, 110.0, 99.0])
      assert_in_delta Enum.at(rs, 0), 0.10, 1.0e-9
      assert_in_delta Enum.at(rs, 1), -0.10, 1.0e-9
    end
  end

  describe "max_drawdown/1" do
    test "a monotonically rising curve has zero drawdown" do
      assert Metrics.max_drawdown([100.0, 101.0, 102.0, 110.0]) == 0.0
    end

    test "computes the largest peak-to-through decline" do
      # peak 120, trough after it 90 -> (120-90)/120 = 0.25
      curve = [100.0, 120.0, 90.0, 110.0]
      assert_in_delta Metrics.max_drawdown(curve), 0.25, 1.0e-9
    end

    test "takes the worst of several drawdowns, not the last" do
      # first dip 100 -> 80 = 0.20 ; recovery to 130 ;
      # second dip to 110 = (130-110)/130 ~= 0.1538. The max is the first, 0.20.
      curve = [100.0, 80.0, 130, 110.0]
      assert_in_delta Metrics.max_drawdown(curve), 0.20, 1.0e-9
    end

    test "empty and single-point curves have zero drawdown" do
      assert Metrics.max_drawdown([]) == 0.0
      assert Metrics.max_drawdown([100.0]) == 0.0
    end
  end

  describe "sharpe/1" do
    test "a flat curve has zero (undefined) Sharpe, not a crash" do
      assert Metrics.sharpe([100.0, 100.0, 100.0]) == 0.0
    end

    test "curves shorter than two returns are zero" do
      assert Metrics.sharpe([]) == 0.0
      assert Metrics.sharpe([100.0]) == 0.0
      assert Metrics.sharpe([100.0, 101.0]) == 0.0
    end

    test "matches a hand-computed value" do
      # returns: 100 -> 110 = 0.10 ; 110 -> 121 = 0.10 => constant 1.0
      # constant returns have zero stddev -> Sharpe defined as 0.0 here.
      assert Metrics.sharpe([100.0, 110.0, 121.0]) == 0.0
    end

    test "positive mean with real dispersion gives a positive Sharpe" do
      # returns alternate +0.20 and 0.00: mean 0.10, some stddev -> Sharpe > 0
      curve = [100.0, 120.0, 120.0, 144.0, 144.0]
      assert Metrics.sharpe(curve) > 0.0
    end

    test "sign follows the mean return" do
      up = [100.0, 105.0, 103.0, 108.0]
      down = [100.0, 95.0, 97.0, 92.0]
      assert Metrics.sharpe(up) > 0.0
      assert Metrics.sharpe(down) < 0.0
    end
  end
end
