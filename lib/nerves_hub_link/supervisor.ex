# SPDX-FileCopyrightText: 2019 Jon Carstens
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Lars Wikman
# SPDX-FileCopyrightText: 2026 Eliel A. Gordon
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Supervisor do
  @moduledoc """
  Supervisor for the NervesHubLink connection processes.

  By default `:nerves_hub_link` starts this supervisor automatically as part
  of its application (see the "Supervision" section of the configuration
  guide). If you'd rather own the lifecycle yourself, set:

      config :nerves_hub_link, start: :manual

  and add this supervisor to your own supervision tree, optionally passing a
  fully built `NervesHubLink.Configurator.Config`:

      children = [
        {NervesHubLink.Supervisor, config: MyApp.build_nh_config()}
      ]

  When no `:config` is provided, the configuration is built from the
  application environment via `NervesHubLink.Configurator.build/0`, which is
  the same behaviour used when the supervisor is auto-started.

  ## Several connections in one VM

  Give each config its own `instance:` and each supervisor its own `:name`
  and the trees stay apart — see `NervesHubLink.Instance`:

      children =
        for {config, i} <- Enum.with_index(configs) do
          Supervisor.child_spec(
            {NervesHubLink.Supervisor,
             config: %{config | instance: i},
             name: NervesHubLink.Instance.name(NervesHubLink.Supervisor, i)},
            id: {NervesHubLink.Supervisor, i}
          )
        end

  ## Options

    * `:config` - a `NervesHubLink.Configurator.Config` struct to use directly.
      Defaults to the result of `NervesHubLink.Configurator.build/0`.
    * `:name` - the name to register the supervisor under. Defaults to
      `NervesHubLink.Supervisor`.
  """

  use Supervisor

  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.Configurator
  alias NervesHubLink.Extensions
  alias NervesHubLink.ExtensionsSupervisor
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Instance
  alias NervesHubLink.Socket
  alias NervesHubLink.SupportScriptsManager
  alias NervesHubLink.UpdateManager

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    # An explicit config wins; otherwise fall back to building it from the
    # application environment so the auto-started path is unchanged.
    config = Keyword.get_lazy(opts, :config, &Configurator.build/0)
    instance = config.instance

    fwup_config = %FwupConfig{
      fwup_devpath: config.fwup_devpath,
      fwup_task: config.fwup_task,
      fwup_extra_options: config.fwup_extra_options,
      fwup_env: config.fwup_env
    }

    children = [
      {DynamicSupervisor, name: Instance.name(ExtensionsSupervisor, instance)},
      {Extensions, instance: instance},
      {UpdateManager, {fwup_config, config.updater, instance}},
      {ArchiveManager, config},
      {Socket, config},
      {Task.Supervisor, name: Instance.name(SupportScriptsTaskSupervisor, instance)},
      {SupportScriptsManager, instance: instance}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
