# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.SocketStub do
  @moduledoc """
  Stands in for `NervesHubLink.Socket` so that tests can observe the status
  updates that would otherwise be pushed to NervesHub.

  `NervesHubLink.send_update_status/1` casts to the process registered as
  `NervesHubLink.Socket`. Without a process under that name the cast is silently
  dropped, so anything that reports progress looks like it is working even when
  it isn't. Registering this stub instead forwards each status to the test
  process as `{:update_status, status}`.
  """

  use GenServer

  @spec start_link(pid() | {pid(), keyword()}) :: GenServer.on_start()
  def start_link(test_pid) when is_pid(test_pid) do
    GenServer.start_link(__MODULE__, test_pid, name: NervesHubLink.Socket)
  end

  # `name:` registers the stub as the socket of a non-default instance, and
  # `tag:` wraps every forwarded message as `{tag, message}` so a test running
  # several stubs can tell them apart.
  def start_link({test_pid, opts}) when is_pid(test_pid) do
    name = Keyword.get(opts, :name, NervesHubLink.Socket)
    state = if tag = opts[:tag], do: {:tagged, tag, test_pid}, else: test_pid
    GenServer.start_link(__MODULE__, state, name: name)
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:send_update_status, status}, state) do
    forward(state, {:update_status, status})
    {:noreply, state}
  end

  def handle_cast(message, state) do
    forward(state, {:socket_cast, message})
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:push, topic, event, payload}, _from, state) do
    forward(state, {:pushed, topic, event, payload})
    {:reply, {:ok, make_ref()}, state}
  end

  defp forward({:tagged, tag, test_pid}, message), do: send(test_pid, {tag, message})
  defp forward(test_pid, message), do: send(test_pid, message)
end
