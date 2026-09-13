# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Instance do
  @moduledoc """
  Names the processes of one NervesHubLink connection.

  A device normally runs a single connection, and every process in that tree
  is registered under its module name: `NervesHubLink.Socket`,
  `NervesHubLink.UpdateManager`, and so on. That is the `:default` instance,
  and nothing about it changes.

  Running more than one connection in the same VM — a test harness driving a
  fleet of virtual devices, say — needs each tree to have its own names.
  Setting `instance:` on the `NervesHubLink.Configurator.Config` passed to
  `NervesHubLink.Supervisor` does that: every process in the tree registers
  in `NervesHubLink.Registry` under `{module, instance}` instead, and the
  processes find each other through `name/2`.

  Processes that are not registered themselves (an updater, a downloader)
  work out which instance they belong to by walking `$ancestors`, so the
  status reports they send land on the right socket without every call
  site having to be told.
  """

  @registry NervesHubLink.Registry
  @default :default

  @type t :: term()

  @doc "The instance a tree runs as when none is configured."
  @spec default() :: :default
  def default(), do: @default

  @doc false
  @spec registry() :: NervesHubLink.Registry
  def registry(), do: @registry

  @doc "Child spec for the registry every non-default instance registers in."
  @spec registry_spec() :: {Registry, keyword()}
  def registry_spec(), do: {Registry, keys: :unique, name: @registry}

  @doc """
  The name a `module`'s process registers under for `instance`.

  The default instance keeps the bare module name so existing code that
  calls `NervesHubLink.Socket` and friends directly keeps working.
  """
  @spec name(module(), t()) :: module() | {:via, Registry, {atom(), {module(), t()}}}
  def name(module, instance \\ @default)
  def name(module, @default), do: module
  def name(module, instance), do: {:via, Registry, {@registry, {module, instance}}}

  @doc "The pid registered for `module` in `instance`, or `nil`."
  @spec whereis(module(), t()) :: pid() | nil
  def whereis(module, instance \\ @default) do
    case GenServer.whereis(name(module, instance)) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  @doc """
  The instance the calling process belongs to.

  Looks the process itself up in the registry, then each of its
  `$ancestors` in turn, and falls back to the default instance when none
  of them is registered — which is what every process of a default tree
  looks like, since those register by plain name.
  """
  @spec current() :: t()
  def current() do
    ancestors = Process.get(:"$ancestors", [])

    [self() | Enum.filter(ancestors, &is_pid/1)]
    |> Enum.find_value(@default, &instance_of/1)
  end

  defp instance_of(pid) do
    case Registry.keys(@registry, pid) do
      [{_module, instance} | _] -> instance
      _ -> nil
    end
  rescue
    # No registry: the application isn't running (some tests) and there can
    # only be the default instance.
    ArgumentError -> nil
  end
end
