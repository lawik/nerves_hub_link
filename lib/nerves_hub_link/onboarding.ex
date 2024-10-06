defmodule NervesHubLink.OnboardSharedSecret do
  @moduledoc """
  Onboarding for devices using the Shared Secret mechanism.

  A temporary, manually invoked process using Phoenix Channels that allows an operator
  to onboard the device from a phone or similar, on site.
  """

  use Slipstream, restart: :temporary

  require Logger

  def start_link(config) do
    Slipstream.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl Slipstream
  def init(config) do
    {callback, config} = Keyword.pop!(config, :callback)
    {:ok, socket} = connect(config)
    {:ok, assign(socket, callback: callback)}
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("Connected onboarding socket...")
    {:ok, join(socket, "onboarding")}
  end

  @impl Slipstream
  def handle_join("onboarding", %{"token" => token, "url" => _url} = msg, socket) do
    Logger.info("Onboarding channel join. Received token: #{token}")
    # The device should now display a URL with the token
    socket.callback.(:start, msg)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(
        "onboarding",
        "success",
        %{"host" => _host, "key" => _key, "secret" => _secret} = msg,
        socket
      ) do
    Logger.info("Onboarding succeeded.")
    socket.callback.(:success, msg)

    {:ok, socket}
  end
end
