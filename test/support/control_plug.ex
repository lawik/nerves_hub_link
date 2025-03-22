# SPDX-FileCopyrightText: 2023 Eric Oestrich
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.ControlPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  require Logger

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, opts) do
    # Pass control to the test
    expect(conn, opts)
  end

  defp expect(conn, opts) do
    send(opts[:test], {:waiting, self()})
    receive do
      {:continue, fun} ->
        fun.(conn)
    after
      5_000 ->
        Logger.error("No control of ControlPlug in 5000ms...")
        conn
    end
  end

  def ctrl(fun) do
    receive do
      {:waiting, pid} ->
        send(pid, {:continue, fun})
    after
      5_000 ->
        Logger.error("No message from ControlPlug in 5000ms...")
    end
  end
end
