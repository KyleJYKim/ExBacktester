defmodule ExBacktester.Bar do
  @moduledoc """
  A single daily OHLCV bar. The only market-data type in the system.

  Floats are fine for a backtester at this scope (v0.1 rule: no Decimal,
  no money-precision rabbit hole).
  """

  @enforce_keys [:date, :open, :high, :low, :close, :volume]
  defstruct [:date, :open, :high, :low, :close, :volume]

  @type t :: %__MODULE__{
          date: Date.t(),
          open: float(),
          high: float(),
          low: float(),
          close: float(),
          volume: non_neg_integer()
        }
end
