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
      assert_in_delta Metrics.total_return([100.0, 105.0, 110.0]), 1.10, 1.0e-9
    end

    test "handles a loss" do
      # 100 -> 80 is -20%
      assert_in_delta Metrics.total_return([100.0, 90.0, 80.0]), -0.20, 1.0e-9
    end
  end


end
