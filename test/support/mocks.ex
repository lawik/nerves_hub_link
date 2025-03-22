# SPDX-FileCopyrightText: 2018 Connor Rigby
# SPDX-FileCopyrightText: 2019 Frank Hunleth
# SPDX-FileCopyrightText: 2020 Jon Carstens
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ClientMock do
  @moduledoc """
  Mock NervesHubLink.Client implementation

  This client always accepts an update.
  """

  @behaviour NervesHubLink.Client

  alias Nerves.Runtime.KV

  require Logger

  @impl NervesHubLink.Client
  def update_available(update_info) do
    if update_info.firmware_meta.uuid == KV.get_active("nerves_fw_uuid") do
      Logger.info("""
      [NervesHubLink.Client] Ignoring request to update to the same firmware

      #{inspect(update_info)}
      """)

      :ignore
    else
      :apply
    end
  end

  @impl NervesHubLink.Client
  def archive_available(archive_info) do
    Logger.info(
      "[NervesHubLink.Client] Archive is available for downloading #{inspect(archive_info)}"
    )

    :ignore
  end

  @impl NervesHubLink.Client
  def archive_ready(archive_info, file_path) do
    Logger.info(
      "[NervesHubLink.Client] Archive is ready for processing #{inspect(archive_info)} at #{inspect(file_path)}"
    )

    :ok
  end

  @impl NervesHubLink.Client
  def handle_message({:progress, percent}, client_config) do
    Logger.debug("[NervesHubLink] PROG: #{percent}%")
  end

  def handle_message({:error, _, message}, client_config) do
    Logger.error("[NervesHubLink] ERROR: #{message}")
  end

  def handle_message({:warning, _, message}, client_config) do
    Logger.warning("[NervesHubLink] WARN: #{message}")
  end

  def handle_message({:ok, status, message}, client_config) do
    Logger.info("[NervesHubLink] FWUP SUCCESS: #{status} #{message}")
  end

  def handle_message(fwup_message) do
    Logger.warning("[NervesHubLink] Unknown FWUP message: #{inspect(fwup_message)}")
  end

  @impl NervesHubLink.Client
  def handle_error(error) do
    Logger.warning("[NervesHubLink] error: #{inspect(error)}")
  end

  @impl NervesHubLink.Client
  def reconnect_backoff() do
    socket_config = Application.get_env(:nerves_hub_link, :socket, [])
    socket_config[:reconnect_after_msec]
  end

  @impl NervesHubLink.Client
  def identify() do
    Logger.info("[NervesHubLink] identifying")
  end

  @impl NervesHubLink.Client
  def reboot() do
    Logger.info("FAKE REBOOT")
  end
end
