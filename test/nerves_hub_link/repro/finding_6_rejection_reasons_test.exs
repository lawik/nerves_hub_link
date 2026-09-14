# SPDX-License-Identifier: Apache-2.0
defmodule NervesHubLink.Repro.Finding6RejectionReasonsTest do
  @moduledoc """
  Reproduces: the `update_rejected` reasons NervesHub sends and the ones this
  client names disagree.

  NervesHub (`DeviceEvents.device_requested_update/1`) answers
  `request_update` with one of `no_deployment_group`, `no_update`,
  `already_updating`. `Socket.update_request_error/1` maps
  `not_permitted`, `unknown_mode`, `no_update`, `no_deployment_group` and
  turns everything else into `:error`, so `already_updating` — the one an
  application most needs to distinguish (it is "try again later", not
  "never") — arrives as `{:error, :error}`. The `busy`/`delay_for` refusal the
  guide documents is not sent by any NervesHub.
  """
  use Slipstream.SocketTest

  import Mox

  alias NervesHubLink.ClientMock
  alias NervesHubLink.ClientStub
  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Socket
  alias NervesHubLink.UpdateManager
  alias NervesHubLink.UpdateManager.UpdaterMock

  @device_topic "device"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub_with(ClientMock, ClientStub)
    stub(ClientMock, :connected, fn -> :ok end)
    stub(ClientMock, :reconnect_backoff, fn -> [1_000] end)
    stub(ClientMock, :firmware_validated?, fn -> true end)
    stub(ClientMock, :firmware_auto_revert_detected?, fn -> false end)
    stub(ClientMock, :handle_error, fn _ -> :ok end)

    data_path = Path.join(System.tmp_dir!(), "repro6_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(data_path) end)

    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(NervesHubLink.Extensions)

    _ =
      start_supervised!(%{
        id: UpdateManager,
        start:
          {UpdateManager, :start_link,
           [
             {%FwupConfig{fwup_devpath: "/tmp/fwup_output", fwup_task: "upgrade"}, UpdaterMock},
             [name: UpdateManager]
           ]}
      })

    socket = start_socket(data_path)
    accept_connect(socket)
    assert_join(@device_topic, _params, :ok)
    answer_network_interface_probe()

    {:ok, socket: socket}
  end

  test "a request refused because the device is already updating says so", %{socket: socket} do
    task = Task.async(fn -> Socket.start_update(socket) end)
    assert_push(@device_topic, "request_update", %{})

    push(socket, @device_topic, "update_rejected", %{"reason" => "already_updating"})

    assert Task.await(task) == {:error, :already_updating}
  end

  defp start_socket(data_path) do
    config = %Config{
      archive_public_keys: ["configured archive key"],
      compress: false,
      connect_wait_for_network: false,
      data_path: data_path,
      fwup_public_keys: ["configured fwup key"],
      heartbeat_interval_msec: 30_000,
      params: %{"device_api_version" => "2.4.0"},
      rejoin_after: [1_000],
      remote_iex: false,
      remote_iex_timeout: 300,
      socket: [
        url: URI.parse("ws://localhost:4000/socket/websocket"),
        reconnect_after_msec: [1_000],
        test_mode?: true
      ],
      ssl: []
    }

    start_supervised!(%{id: Socket, start: {Socket, :start_link, [config, [name: Socket]]}})
  end

  defp answer_network_interface_probe(timeout \\ 1_000) do
    receive do
      {:system, from, _request} -> GenServer.reply(from, {:ok, :no_connection_information})
    after
      timeout -> :ok
    end
  end
end
