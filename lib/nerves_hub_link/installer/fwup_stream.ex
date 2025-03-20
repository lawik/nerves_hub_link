defmodule NervesHubLink.Installer.FwupStream do
  @behaviour NervesHubLink.Installer
  use GenServer

  alias NervesHubLink.UpdateManager

  def start_install(manager, config, firmware_signing_certs) do
    GenServer.start_link(__MODULE__, %{manager: manager, config: config, certs: firmware_signing_certs}, [])
  end

  def validate!(config) do
    fwup_config = %FwupConfig{
      fwup_devpath: config.fwup_devpath,
      fwup_task: config.fwup_task,
      fwup_env: config.fwup_env,
      handle_fwup_message: &Client.handle_fwup_message/1,
      update_available: &Client.update_available/1
    }
    FwupConfig.validate!()
  end

  @impl GenServer
  def init(%{manager: manager, config: config, certs: firmware_signing_certs}) do
    fwup_config = %FwupConfig{
      fwup_devpath: config.fwup_devpath,
      fwup_task: config.fwup_task,
      fwup_env: config.fwup_env,
      handle_fwup_message: &Client.handle_fwup_message/1,
      update_available: &Client.update_available/1
    }
    {:ok, fwup} = Fwup.stream(self(), fwup_args(config, firmware_signing_certs), fwup_env: fwup_config.fwup_env)
    {:ok, %{fwup: fwup, config: config, manager: manager}}
  end

  def send_chunk(installer, chunk) do
    GenServer.call(installer, {:chunk, chunk})
  end

  def send_complete(installer, data) do
    GenServer.call(installer, {:complete, data})
  end

  @impl GenServer
  def handle_call({:chunk, chunk}, _from, state) do
    _ = Fwup.Stream.send_chunk(state.fwup, data)
    {:reply, :ok, state}
  end

  def handle_call({:complete, data}, _from, state) do
    # do nothing ,this is a streaming fwup implementation
    {:reply, :ok, state}
  end

  # messages from FWUP
  @impl GenServer
  def handle_info({:fwup, message}, state) do
    _ = state.config.fwup_config.handle_fwup_message.(message)

    case message do
      {:ok, 0, _message} ->

        Logger.info("[NervesHubLink] FWUP Finished")
        UpdateManager.report_install_status(state.manager, :complete)
        # TODO: shut down installer
        {:noreply, %State{state | fwup: nil}}

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

  @spec fwup_args(FwupConfig.t(), list(String.t())) :: [String.t()]
  defp fwup_args(%FwupConfig{} = config, firmware_signing_certs) do
    args = ["--apply", "--no-unmount", "-d", config.fwup_devpath, "--task", config.fwup_task]

    Enum.reduce(firmware_signing_certs, args, fn public_key, args ->
      args ++ ["--public-key", public_key]
    end)
  end
end
