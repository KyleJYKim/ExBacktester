defmodule ExBacktester do
  @moduledoc """
  Documentation for `ExBacktester`.
  """

  @doc "Just notes; can be deleted anytime"
  def note(:bar) do
    "
    A bar is one unit of price history for a ticker over a fixed time slice -- in this project, one trading day.
    The name comes from how it's drawn on a chart: a single vertical bar (or candle) summarizing everything that happened in that slice, compressed into five numbers -- OHLCV.
    So a bar is a \'summary\' of a period, not a single trade. A backtest is essentially a stream of bars fed through the system one at a time -- `bar.ex:2` calls it \"the only market-data type in the system.\"

    The `sample.csv` is just a list of daily bars.

    Time slices can be any size (1-minute bars, hourly bars, weekly bars).
    The word \"candle\" / \"candlestick\" means the same thing.
    "
  end

  def note(:fill) do
    "
    A fill is the record of an order actually getting executed -- the moment \"I want to buy 100 share\" becomes \"I did buy 100 share at price X.\"
    In markets, submitting an order and it filling are two separate events: an order can sit unfilled, partially fill, or fill at a different price than you hoped.
    A fill captures what really happened.

    In `Broker`, `submit` returns `{:ok, fill}`, and the private `fill/6` builds that record -- side (:buy/:sell), ticker, quantity, price, fee, date. Each fill gets prepended onto `account.trades`, so the trade history is the list of fills.

    The interesting design decision: what price does a fill get?
    The fills at the close of the current bar -- which ties the two terms together.
    The strategy sees today's bar, decides on today's close, and the fill also happens at that close.
    The doc honestly flags this as mild lookahead bias (you can't realistically both observe a closing price and trade at it), with the more realistic alternative being to fill at the next bar's open.
    "
  end
end
