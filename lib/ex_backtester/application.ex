defmodule ExBacktester.Application do
  @moduledoc """
  The supervision tree — the actual learning payload of this project.

      ExBacktester.Supervisor (:one_for_one)
      ├── ExBacktester.Broker              (stub until week 2)
      ├── ExBacktester.Recorder            (stub until week 3)
      ├── ExBacktester.DataFeed
      └── ExBacktester.StrategySupervisor  (DynamicSupervisor)
          └── strategies started at runtime

  Start order matters and is deliberate: Broker and Recorder come up
  before the DataFeed, and strategies are started dynamically last —
  a strategy's `handle_continue` subscribes to the DataFeed, so the
  feed must already be running.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExBacktester.Broker,
      ExBacktester.Recorder,
      ExBacktester.DataFeed,
      {DynamicSupervisor, name: ExBacktester.StrategySupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: ExBacktester.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
