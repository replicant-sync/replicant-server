defmodule ReplicantServer.Feed.Retention do
  @moduledoc "Trims the change feed and stored upload replies once a day."

  use GenServer

  alias ReplicantServer.Feed

  @interval_ms :timer.hours(24)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :trim, Keyword.get(opts, :first_run_ms, :timer.minutes(5)))
    {:ok, opts}
  end

  @impl true
  def handle_info(:trim, opts) do
    Feed.trim(Keyword.get(opts, :days, Feed.retention_days()))
    Process.send_after(self(), :trim, @interval_ms)
    {:noreply, opts}
  end
end
