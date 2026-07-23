defmodule ExBacktester.BrokerTest do
  @moduledoc """
  The Broker is where money arithmetic lives, so it is where a silent bug
  costs you the most: a wrong fee sign or a missed position update does not
  crash anything, it just quietly changes every result downstream.
  Test the arithmetic explicitly.
  """

  use ExUnit.Case, async: false

  alias ExBacktester.{Bar, Broker}

  @ticker "TEST"

  setup do
    # The Broker is a named singleton started by the application, so tests
    # share it. Give each test its own account name instead of trying to
    # reset global state.
    name = :"strategy_#{System.unique_integer([:positive])}"
    :ok = Broker.open_account(name)
    :ok = Broker.mark(bar(100.0))
    %{name: name}
  end

  defp bar(close) do
    %Bar{
      ticker: @ticker,
      date: ~D[2024-01-02],
      open: close,
      high: close,
      low: close,
      close: close,
      volume: 1_000
    }
  end

  test "a new account starts with the full cash balance and no positions", %{name: name} do
    account = Broker.account(name)
    assert account.cash == Broker.starting_cash()
    assert account.positions == %{}
    assert account.trades == []
  end

  test "buying deducts gross plus fee and credits the position", %{name: name} do
    {:ok, fill} = Broker.order(name, :buy, @ticker, 10)

    # 10 shares @ 100.0 = 1000.0 gross, fee = 0.1% = 1.0
    assert fill.qty == 10
    assert fill.price == 100.0
    assert_in_delta fill.fee, 1.0, 0.0001

    account = Broker.account(name)
    assert_in_delta account.cash, Broker.starting_cash() - 1001.0, 0.0001
    assert account.positions[@ticker] == 10
  end

  test "selling credits gross minus fee and debits the position", %{name: name} do
    {:ok, _} = Broker.order(name, :buy, @ticker, 10)
    :ok = Broker.mark(bar(110.0))
    {:ok, fill} = Broker.order(name, :sell, @ticker, 10)

    # sold 10 @ 110.0 = 1100.0 gross, fee = 1.10
    assert fill.side == :sell
    assert_in_delta fill.fee, 1.10, 0.0001

    account = Broker.account(name)
    assert account.positions[@ticker] == 0

    # bought at 100 (cost 1001.0), sold at 110 (received 1098.90)
    expected = Broker.starting_cash() - 1001.0 + 1098.90
    assert_in_delta account.cash, expected, 0.0001
  end

  test "fees make a flat round-trip a small loss", %{name: name} do
    {:ok, _} = Broker.order(name, :buy, @ticker, 10)
    {:ok, _} = Broker.order(name, :sell, @ticker, 10)

    # Same price in and out: you lose exactly both fees (1.0 + 1.0).
    # If this test ever passes with zero loss, fees are not being applied.
    account = Broker.account(name)
    assert_in_delta account.cash, Broker.starting_cash() - 2.0, 0.0001
  end

  test "an order that exceeds cash is rejected, not partially filled", %{name: name} do
    assert {:error, :insufficient_cash} = Broker.order(name, :buy, @ticker, 100_000)

    account = Broker.account(name)
    assert account.cash == Broker.starting_cash()
    assert account.positions == %{}
  end

  test "selling more than held is rejected (long-only, no shorting)", %{name: name} do
    {:ok, _} = Broker.order(name, :buy, @ticker, 5)
    assert {:error, :insufficient_position} = Broker.order(name, :sell, @ticker, 10)
    assert Broker.account(name).positions[@ticker] == 5
  end

  test "equity marks open positions at the latest price", %{name: name} do
    {:ok, _} = Broker.order(name, :buy, @ticker, 10)

    # unrealised gain of 10 * 20.0 = 200.0 once the price moves to 120
    :ok = Broker.mark(bar(120.0))

    expected = Broker.starting_cash() - 1001.0 + 10 * 120.0
    assert_in_delta Broker.equity(name), expected, 0.0001
  end

  test "every fill is appended to the trade log", %{name: name} do
    {:ok, _} = Broker.order(name, :buy, @ticker, 1)
    {:ok, _} = Broker.order(name, :sell, @ticker, 1)

    assert length(Broker.account(name).trades) == 2
  end
end
