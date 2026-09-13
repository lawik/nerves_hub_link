# SPDX-FileCopyrightText: 2026 Eliel A. Gordon
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SupervisorTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.UpdateManager.StreamingUpdater

  # `init/1` is a pure function that returns the normalized child specs, so we
  # can assert on the wiring without booting the (networked) child processes.
  defp child_start_modules({:ok, {_flags, specs}}) do
    Enum.map(specs, fn %{start: {mod, _fun, _args}} -> mod end)
  end

  defp child_spec_for({:ok, {_flags, specs}}, mod) do
    Enum.find(specs, fn %{start: {m, _fun, _args}} -> m == mod end)
  end

  test "init/1 wires up the expected children in order" do
    result = NervesHubLink.Supervisor.init(config: %Config{})

    assert {:ok, {%{strategy: :one_for_one}, _specs}} = result

    assert child_start_modules(result) == [
             DynamicSupervisor,
             NervesHubLink.Extensions,
             NervesHubLink.UpdateManager,
             NervesHubLink.ArchiveManager,
             NervesHubLink.Socket,
             Task.Supervisor,
             NervesHubLink.SupportScriptsManager
           ]
  end

  test "init/1 threads the given config into the update manager" do
    config = %Config{
      fwup_devpath: "/dev/loop0",
      fwup_task: "upgrade",
      fwup_extra_options: ["--unsafe"],
      fwup_env: [{"KEY", "VALUE"}],
      updater: StreamingUpdater
    }

    result = NervesHubLink.Supervisor.init(config: config)

    %{start: {_mod, _fun, [{fwup_config, updater} | _]}} =
      child_spec_for(result, NervesHubLink.UpdateManager)

    assert fwup_config == %FwupConfig{
             fwup_devpath: "/dev/loop0",
             fwup_task: "upgrade",
             fwup_extra_options: ["--unsafe"],
             fwup_env: [{"KEY", "VALUE"}]
           }

    assert updater == StreamingUpdater
  end

  test "init/1 falls back to Configurator.build/0 when no config is given" do
    # No :config option means the old application-environment path is used.
    assert {:ok, {%{strategy: :one_for_one}, specs}} = NervesHubLink.Supervisor.init([])
    assert length(specs) == 7
  end

  test "the application does not auto-start children when connect: false" do
    # The test environment sets `connect: false`, so the application-level
    # supervisor should come up with nothing but the instance registry, which
    # is always there so a manually supervised tree can register in it.
    assert is_pid(Process.whereis(NervesHubLink.ApplicationSupervisor))

    assert [{NervesHubLink.Registry, _pid, :supervisor, _}] =
             Supervisor.which_children(NervesHubLink.ApplicationSupervisor)
  end

  test "init/1 scopes every child to the configured instance" do
    {:ok, {_flags, specs}} = NervesHubLink.Supervisor.init(config: %Config{instance: :fleet_7})

    # Every child either registers under a `{module, :fleet_7}` registry key
    # or is handed the instance to derive that name itself. Either way no
    # process may end up on a plain module name, where it would collide with
    # a default tree in the same VM.
    assert length(specs) == 7

    for %{start: {mod, _fun, args}} <- specs do
      assert scoped?(args), "#{inspect(mod)} is not scoped to the instance: #{inspect(args)}"
    end
  end

  test "init/1 keeps the default instance on plain module names" do
    {:ok, {_flags, specs}} = NervesHubLink.Supervisor.init(config: %Config{})

    socket = child_spec_for({:ok, {nil, specs}}, NervesHubLink.Socket)
    assert %{start: {NervesHubLink.Socket, :start_link, [%Config{instance: :default}]}} = socket

    manager = child_spec_for({:ok, {nil, specs}}, NervesHubLink.UpdateManager)
    assert %{start: {_, _, [_, [name: NervesHubLink.UpdateManager]]}} = manager
  end

  defp scoped?([%Config{instance: :fleet_7}]), do: true
  defp scoped?([%Config{instance: :fleet_7}, opts]), do: via?(opts[:name])
  defp scoped?([{%FwupConfig{}, _updater} | [opts]]), do: via?(opts[:name])
  defp scoped?([opts]) when is_list(opts), do: via?(opts[:name]) or opts[:instance] == :fleet_7

  defp via?({:via, Registry, {NervesHubLink.Registry, {_module, :fleet_7}}}), do: true
  defp via?(_), do: false
end
