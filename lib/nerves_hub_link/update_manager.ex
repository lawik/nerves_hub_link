# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Connor Rigby
# SPDX-FileCopyrightText: 2024 Frank Hunleth
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManager do
  @moduledoc """
  GenServer responsible for brokering messages between:
    * an external controlling process
    * FWUP
    * HTTP

  Should be started in a supervision tree
  """
  use GenServer

  alias NervesHubLink.Client
  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.Downloader
  alias NervesHubLink.Installer
  alias NervesHubLink.Message.UpdateInfo
  alias NervesHubLink.UpdateManager

  require Logger

  @type status ::
          :idle
          | {:error, :install | :download, String.t()}
          | :update_rescheduled
          | :updating

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            status: UpdateManager.status(),
            update_reschedule_timer: nil | :timer.tref(),
            downloader: nil | GenServer.server(),
            installer: nil | GenServer.server(),
            config: Config.t(),
            update_info: nil | UpdateInfo.t(),
            progress: %{download: integer(), install: integer()}
          }

    defstruct status: :idle,
              update_reschedule_timer: nil,
              installer: nil,
              downloader: nil,
              config: nil,
              update_info: nil,
              progress: nil
  end

  @doc """
  Must be called when an update payload is dispatched from
  NervesHub. the map must contain a `"firmware_url"` key.
  """
  @spec apply_update(GenServer.server(), UpdateInfo.t(), list(String.t())) :: UpdateManager.status()
  def apply_update(manager \\ __MODULE__, %UpdateInfo{} = update_info, firmware_signing_certs) do
    GenServer.call(manager, {:apply_update, update_info, firmware_signing_certs})
  end

  @doc """
  Returns the current status of the update manager
  """
  @spec status(GenServer.server()) :: UpdateManager.status()
  def status(manager \\ __MODULE__) do
    GenServer.call(manager, :status)
  end

  @doc """
  Returns the UUID of the currently downloading firmware, or nil.
  """
  @spec currently_downloading_uuid(GenServer.server()) :: uuid :: String.t() | nil
  def currently_downloading_uuid(manager \\ __MODULE__) do
    GenServer.call(manager, :currently_downloading_uuid)
  end

  @spec report_download_status(manager :: GenServer.server(), message :: term()) :: :ok
  def report_download_status(manager, message) do
    # High timeout to be resilient to delays in decompression
    GenServer.call(manager, {:download, message}, 60_000)
  end

  @spec report_install_status(manager :: GenServer.server(), message :: term()) :: :ok
  def report_install_status(manager, message) do
    # High timeout to be resilient to delays in decompression
    GenServer.call(manager, {:install, message}, 60_000)
  end

  @doc false
  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = args) do
    %{
      start: {__MODULE__, :start_link, [args, [name: __MODULE__]]},
      id: __MODULE__
    }
  end

  @doc false
  @spec start_link(Config.t(), GenServer.options()) :: GenServer.on_start()
  def start_link(%Config{} = args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  @impl GenServer
  def init(%Config{} = config) do
    :alarm_handler.clear_alarm(NervesHubLink.UpdateInProgress)
    # Fail immediately on bad config
    Installer.installer().validate_config!(config)
    {:ok, %State{config: config}}
  end

  @impl GenServer
  def handle_call(
        {:apply_update, %UpdateInfo{} = update, firmware_signing_certs},
        _from,
        %State{} = state
      ) do
    state = maybe_update_firmware(update, firmware_signing_certs, state)
    {:reply, state.status, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %State{update_info: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %State{} = state) do
    {:reply, state.update_info.firmware_meta.uuid, state}
  end

  def handle_call(:status, _from, %State{} = state) do
    {:reply, state.status, state}
  end

  # messages from Downloader
  def handle_call({:download, {:complete, data}}, _from, state) do
    Logger.info("[NervesHubLink] Firmware Download complete")
    Installer.installer().send_complete(state.installer, data)
    {:reply, :ok, %State{state | downloader: nil}}
  end

  def handle_call({:download, {:error, reason}}, _from, state) do
    Logger.error("[NervesHubLink] Nonfatal HTTP download error: #{inspect(reason)}")
    NervesHubLink.send_update_status("download error #{inspect(reason)}")
    {:reply, :ok, state}
  end

  # Data from the downloader is sent to fwup
  def handle_call({:download, {:data, data}}, _from, state) do
    # Backwards-compatible progress report
    ((state.progress.download + state.progress.install) / 2)
    |> round()
    |> NervesHubLink.send_update_progress()

    # TODO: Report download progress upwards to the socket
    # currently only reporting on fwup progress
    Installer.installer().send_chunk(state.installer, data)
    {:reply, :ok, state}
  end

  def handle_call({:install, :complete}, _from, state) do
    :alarm_handler.clear_alarm(NervesHubLink.UpdateInProgress)
    state.config.client.initiate_reboot()
    state = %State{state | installer: nil, update_info: nil, status: :idle}
    {:reply, :ok, state}
  end

  def handle_call({:install, {:progress, percent}}, _from, state) do
    # Backwards-compatible progress report
    ((state.progress.download + state.progress.install) / 2)
    |> round()
    |> NervesHubLink.send_update_progress()

    state = %State{state | status: :updating, progress: %{state.progress | install: percent}}
    {:reply, :ok, state}
  end

  def handle_call({:install, {:error, message}}, _from, state) do
    :alarm_handler.clear_alarm(NervesHubLink.UpdateInProgress)
    NervesHubLink.send_update_status("install error #{message}")
    state = %State{state | status: {:error, :install, message}}
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:update_reschedule, response, firmware_signing_certs}, state) do
    {:noreply,
     maybe_update_firmware(response, firmware_signing_certs, %State{
       state
       | update_reschedule_timer: nil
     })}
  end


  @spec maybe_update_firmware(UpdateInfo.t(), [binary()], State.t()) :: State.t()
  defp maybe_update_firmware(
         %UpdateInfo{} = _update_info,
         _firmware_signing_certs,
         %State{status: :updating} = state
       ) do
    # Received an update message from NervesHub, but we're already in progress.
    # It could be because the deployment/device was edited making a duplicate
    # update message or a new deployment was created. Either way, lets not
    # interrupt FWUP and let the task finish. After update and reboot, the
    # device will check-in and get an update message if it was actually new and
    # required
    state
  end

  defp maybe_update_firmware(%UpdateInfo{} = update_info, firmware_signing_certs, %State{} = state) do
    # Cancel an existing timer if it exists.
    # This prevents rescheduled updates`
    # from compounding.
    state = maybe_cancel_timer(state)

    # possibly offload update decision to an external module.
    # This will allow application developers
    # to control exactly when an update is applied.
    case state.config.client.update_available(update_info) do
      :apply ->
        start_update(update_info, firmware_signing_certs, state)

      :ignore ->
        state

      {:reschedule, ms} ->
        timer =
          Process.send_after(self(), {:update_reschedule, update_info, firmware_signing_certs}, ms)

        Logger.info("[NervesHubLink] rescheduling firmware update in #{ms} milliseconds")
        %{state | status: :update_rescheduled, update_reschedule_timer: timer}
    end
  end

  defp maybe_update_firmware(_, _, state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: nil} = state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: timer} = state) do
    _ = Process.cancel_timer(timer)

    %{state | update_reschedule_timer: nil}
  end

  @spec start_update(UpdateInfo.t(), [binary()], State.t()) :: State.t()
  defp start_update(%UpdateInfo{} = update_info, firmware_signing_certs, state) do
    {:ok, downloader} = Downloader.downloader().start_download(__MODULE__, self(), URI.parse(update_info.firmware_url), state.config)

    {:ok, installer} = Installer.installer().start_install(self(), state.config, firmware_signing_certs)
    Logger.info("[NervesHubLink] Downloading firmware: #{update_info.firmware_url}")
    :alarm_handler.set_alarm({NervesHubLink.UpdateInProgress, []})

    %State{
      state
      | status: :updating,
        progress: %{download: 0, install: 0},
        downloader: downloader,
        installer: installer,
        update_info: update_info
    }
  end
end
