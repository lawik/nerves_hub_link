# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Downloader do
  @moduledoc """
  Behaviour for

  The downloader sends status messages to the manager:
  """

  alias NervesHubLink.Configurator.Config

  # Callback for starting should be idempotent. The same download can be told to start again
  # typically to refresh an expired authentication by replacing the URI
  @callback start_download(manager :: GenServer.server(), uri :: URI.t(), config :: Config.t()) :: {:ok, GenServer.server()}

  @default_downloader NervesHubLink.Downloader.StreamingHTTP
  def downloader() do
    Application.get_env(:nerves_hub_link, :downloader, @default_downloader)
  end

  def archive_downloader() do
    Application.get_env(:nerves_hub_link, :archive_downloader, @default_downloader)
  end
end
