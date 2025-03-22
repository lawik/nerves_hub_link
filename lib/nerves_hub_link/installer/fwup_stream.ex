defmodule NervesHubLink.Installer.FwupStream do
  @behaviour NervesHubLink.Installer
  use GenServer

  alias NervesHubLink.Client
  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.UpdateManager

  require Logger

  @impl NervesHubLink.Installer
  def start_install(manager, config, firmware_signing_certs) do
    GenServer.start_link(__MODULE__, %{manager: manager, config: config, certs: firmware_signing_certs}, [])
  end

  @impl NervesHubLink.Installer
  def validate_config!(config) do
    FwupConfig.validate!(config)
  end

  @impl GenServer
  def init(%{manager: manager, config: config, certs: firmware_signing_certs}) do
    {:ok, fwup} = Fwup.stream(self(), fwup_args(config, firmware_signing_certs), fwup_env: config.fwup_env)
    {:ok, %{fwup: fwup, config: config, manager: manager}}
  end

  @impl NervesHubLink.Installer
  def send_chunk(installer, chunk) do
    GenServer.call(installer, {:chunk, chunk})
  end

  @impl NervesHubLink.Installer
  def send_complete(installer, data) do
    GenServer.call(installer, {:complete, data})
  end

  @impl GenServer
  def handle_call({:chunk, chunk}, _from, state) do
    _ = Fwup.Stream.send_chunk(state.fwup, chunk)
    {:reply, :ok, state}
  end

  def handle_call({:complete, _data}, _from, state) do
    # do nothing ,this is a streaming fwup implementation
    {:reply, :ok, state}
  end

  # messages from FWUP
  @impl GenServer
  def handle_info({:fwup, message}, state) do
    _ = state.config.client.handle_message(message, state.config.client_config)

    case message do
      {:ok, 0, _message} ->

        Logger.info("[NervesHubLink] FWUP Finished")
        UpdateManager.report_install_status(state.manager, :complete)
        # TODO: shut down installer
        {:stop, :normal, %{state | fwup: nil}}

      {:progress, percent} ->
        UpdateManager.report_install_status(state.manager, {:progress, percent})
        {:noreply, state}

      {:error, _, message} ->
        UpdateManager.report_install_status(state.manager, {:error, message})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @spec fwup_args(Config.t(), list(String.t())) :: [String.t()]
  defp fwup_args(%Config{} = config, firmware_signing_certs) do
    args = ["--apply", "--no-unmount", "-d", config.fwup_devpath, "--task", config.fwup_task]

    Enum.reduce(firmware_signing_certs, args, fn public_key, args ->
      args ++ ["--public-key", public_key]
    end)
  end
end
