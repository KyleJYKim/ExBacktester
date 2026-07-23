defmodule ExBacktester.Bar do
  @moduledoc """
  A single daily OHLCV bar for one ticker. The only market-data type
  in the system.

  Floats are fine for a backtester at this scope (v0.1 rule: no Decimal,
  no money-precision rabbit hole).
  """

  @enforce_keys [:ticker, :date, :open, :high, :low, :close, :volume]
  defstruct [:ticker, :date, :open, :high, :low, :close, :volume]

  @type t :: %__MODULE__{
          ticker: String.t(),
          date: Date.t(),
          open: float(),
          high: float(),
          low: float(),
          close: float(),
          volume: non_neg_integer()
        }
end
