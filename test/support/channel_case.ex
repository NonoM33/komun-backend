defmodule KomunBackendWeb.ChannelCase do
  @moduledoc """
  Test helpers for Phoenix Channels.

  Imports `Phoenix.ChannelTest` and `KomunBackendWeb.ChannelCase` itself, and
  wires up the Ecto sandbox so channel tests share the standard data setup.

  `use KomunBackendWeb.ChannelCase, async: true` for tests that don't need
  shared sandbox; default async: false.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import KomunBackendWeb.ChannelCase

      @endpoint KomunBackendWeb.Endpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(KomunBackend.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
