# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.InstanceTest.Echo do
  @moduledoc """
  An extension that answers every event with a push, so a test can see which
  socket an extension process reports through.
  """

  use NervesHubLink.Extensions, name: "echo", version: "0.0.1"

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl NervesHubLink.Extensions
  def handle_event(event, payload, state) do
    _ = push("echoed", %{"event" => event, "payload" => payload})
    {:noreply, state}
  end
end

defmodule NervesHubLink.InstanceTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Extensions
  alias NervesHubLink.ExtensionsSupervisor
  alias NervesHubLink.Instance
  alias NervesHubLink.InstanceTest.Echo
  alias NervesHubLink.Socket
  alias NervesHubLink.Support.SocketStub

  setup do
    previous = Application.get_env(:nerves_hub_link, :extension_modules)
    Application.put_env(:nerves_hub_link, :extension_modules, [Echo])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_hub_link, :extension_modules, previous),
        else: Application.delete_env(:nerves_hub_link, :extension_modules)
    end)

    # Two complete extension trees, one per instance, each with its own
    # socket stub. Nothing here is registered under a plain module name.
    for instance <- [:a, :b] do
      start_supervised!(
        {SocketStub, {self(), name: Instance.name(Socket, instance), tag: instance}},
        id: {:socket, instance}
      )

      start_supervised!({DynamicSupervisor, name: Instance.name(ExtensionsSupervisor, instance)},
        id: {:sup, instance}
      )

      start_supervised!({Extensions, instance: instance}, id: {:extensions, instance})
    end

    :ok
  end

  test "naming keeps the default instance on plain module names" do
    assert Instance.name(Socket) == Socket
    assert Instance.name(Socket, Instance.default()) == Socket

    assert Instance.name(Socket, :a) ==
             {:via, Registry, {NervesHubLink.Registry, {Socket, :a}}}
  end

  test "each instance's extensions attach through their own socket" do
    :ok = Extensions.attach(Instance.name(Extensions, :a), ["echo"])

    assert_receive {:a, {:pushed, "extensions", "echo:attached", %{}}}
    refute_receive {:b, {:pushed, "extensions", "echo:attached", %{}}}, 100

    refute Process.whereis(Echo)
    assert is_pid(Instance.whereis(Echo, :a))
    refute Instance.whereis(Echo, :b)
  end

  test "an extension process pushes through the instance it was started in" do
    for instance <- [:a, :b] do
      :ok = Extensions.attach(Instance.name(Extensions, instance), ["echo"])
      assert_receive {^instance, {:pushed, "extensions", "echo:attached", %{}}}
    end

    :ok = Extensions.handle_event(Instance.name(Extensions, :b), "echo:ping", %{"n" => 1})

    assert_receive {:b, {:pushed, "extensions", "echo:echoed", %{"event" => "ping"}}}
    refute_receive {:a, {:pushed, "extensions", "echo:echoed", _}}, 100
  end

  test "detaching one instance leaves the other attached" do
    for instance <- [:a, :b] do
      :ok = Extensions.attach(Instance.name(Extensions, instance), ["echo"])
      assert_receive {^instance, {:pushed, "extensions", "echo:attached", %{}}}
    end

    :ok = Extensions.detach(Instance.name(Extensions, :a), :all)
    assert_receive {:a, {:pushed, "extensions", "echo:detached", %{}}}

    refute Instance.whereis(Echo, :a)
    assert is_pid(Instance.whereis(Echo, :b))
  end

  test "current/0 is resolved through the process ancestry" do
    assert Instance.current() == Instance.default()

    # A process started under an instance's extension tree, and a task
    # started under that, both belong to the instance.
    :ok = Extensions.attach(Instance.name(Extensions, :a), ["echo"])
    assert_receive {:a, {:pushed, "extensions", "echo:attached", %{}}}
    echo = Instance.whereis(Echo, :a)

    test_pid = self()

    :sys.replace_state(echo, fn state ->
      spawn_link(fn ->
        Process.put(:"$ancestors", [echo])
        send(test_pid, {:current, Instance.current()})
      end)

      state
    end)

    assert_receive {:current, :a}
  end
end
