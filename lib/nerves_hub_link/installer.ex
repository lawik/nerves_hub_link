defmodule NervesHubLink.Installer do
  @moduledoc """
  Behaviour for ..


  """

  alias NervesHubLink.Configurator.Config

  @callback start_install(manager :: GenServer.server(), config :: Config.t(), firmware_signing_certs :: [binary()]) :: {:ok, GenServer.server()}
  @callback validate_config!(config :: Config.t()) :: :ok
  @callback send_chunk(installer :: GenServer.server(), chunk :: term()) :: :ok
  @callback send_complete(installer :: GenServer.server(), data :: term()) :: :ok

  @default_installer NervesHubLink.Installer.FwupStream
  def installer() do
    Application.get_env(:nerves_hub_link, :installer, @default_installer)
  end
end
