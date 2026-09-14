# SPDX-License-Identifier: Apache-2.0
defmodule NervesHubLink.Repro.Finding4HandleReplyCrashTest do
  @moduledoc """
  Reproduces: any channel reply other than `{:error, "detach"}` crashes the
  socket.

  `NervesHubLink.Socket.handle_reply/3` has a single clause. Phoenix replies
  to every push that carries a ref; one it can send at any time is
  `{:error, %{"reason" => "unmatched topic"}}`, for a push that reaches the
  server after its channel process died (a channel crash on the hub, a
  rejoin in progress). Observed live: the device channel crashed, the
  device's next `status_update` was answered "unmatched topic", and the
  socket died with a `FunctionClauseError`, taking the parked
  device-managed request and the reconnect backoff with it.
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

    data_path = Path.join(System.tmp_dir!(), "repro4_#{System.unique_integer([:positive])}")
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

    _ = start_supervised!({Task.Supervisor, name: Repro4Tasks})

    socket = start_socket(data_path)
    accept_connect(socket)
    assert_join(@device_topic, _params, :ok)
    answer_network_interface_probe()

    {:ok, socket: socket}
  end

  test "an unexpected error reply does not take the socket down", %{socket: socket} do
    pid = Process.whereis(Socket)

    # Not linked to this test: if the socket dies the caller's exit must not
    # abort the test before it can say what happened.
    task = Task.Supervisor.async_nolink(Repro4Tasks, fn -> Socket.check_for_update(socket) end)
    assert_push(@device_topic, "check_update", %{}, ref)

    # The channel this push was for is gone; Phoenix says so.
    reply(socket, ref, {:error, %{"reason" => "unmatched topic"}})
    Process.sleep(100)

    assert Process.alive?(pid), "the socket crashed on an error reply it had no clause for"
    assert Process.whereis(Socket) == pid, "the socket was restarted by its supervisor"

    # The parked caller is still owed its answer.
    push(socket, @device_topic, "update_available", %{
      "available" => false,
      "firmware_meta" => nil
    })

    assert {:ok, {:ok, %{available?: false}}} = Task.yield(task, 2_000)
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
