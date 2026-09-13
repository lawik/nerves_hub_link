# SPDX-License-Identifier: Apache-2.0
defmodule NervesHubLink.Repro.Finding2UncorrelatedAnswersTest do
  @moduledoc """
  Reproduces: the answer to a device-initiated request is not correlated to
  the request.

  `Socket.resolve_update_request/3` resolves a parked `start_update/1` or
  `set_update_mode/2` caller from the next `update`/`update_rejected` or
  `update_mode` message, whoever sent it and whatever it was about. NervesHub
  pushes all of these unsolicited too (a deployment or manual push, the mode
  report on join or on an operator change), so a caller can be told `:ok` by
  a message that was not the answer, and the real answer is then dropped.

  Both tests drive `NervesHubLink.Socket` as the server via
  `Slipstream.SocketTest`, the way `socket_messages_test.exs` does.
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

    data_path = Path.join(System.tmp_dir!(), "repro2_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(data_path) end)

    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(NervesHubLink.Extensions)

    _ =
      start_supervised!(%{
        id: UpdateManager,
        start:
          {UpdateManager, :start_link,
           [{%FwupConfig{fwup_devpath: "/tmp/fwup_output", fwup_task: "upgrade"}, UpdaterMock}, [name: UpdateManager]]}
      })

    _ =
      start_supervised!(%{
        id: NervesHubLink.ArchiveManager,
        start: {NervesHubLink.ArchiveManager, :start_link, [%{data_path: data_path}, [name: NervesHubLink.ArchiveManager]]}
      })

    _ = start_supervised!({Task.Supervisor, name: SupportScriptsTaskSupervisor})
    _ = start_supervised!(NervesHubLink.SupportScriptsManager)

    socket = start_socket(data_path)
    accept_connect(socket)
    assert_join(@device_topic, _params, :ok)
    answer_network_interface_probe()

    {:ok, socket: socket}
  end

  test "set_update_mode is not resolved by a mode report that is not its answer", %{socket: socket} do
    task = Task.async(fn -> Socket.set_update_mode(socket, :device_managed) end)
    assert_push(@device_topic, "set_update_mode", %{mode: :device_managed})

    # An operator granted managed updates while the request was in flight:
    # NervesHub reports the current mode unasked. This is not the answer.
    push(socket, @device_topic, "update_mode", %{"mode" => "automatic", "managed_updates_allowed" => true})

    # The answer: the change was refused.
    push(socket, @device_topic, "update_mode", %{
      "mode" => "automatic",
      "managed_updates_allowed" => true,
      "error" => "not_permitted"
    })

    assert Task.await(task) == {:error, :not_permitted}
    assert Socket.update_mode(socket) == :automatic
  end

  test "start_update is not resolved by an update it did not ask for", %{socket: socket} do
    expect(UpdaterMock, :start_update, fn _update_info, _fwup_config, _keys ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)

    task = Task.async(fn -> Socket.start_update(socket) end)
    assert_push(@device_topic, "request_update", %{})

    # An operator's manual push reaches the device before NervesHub has
    # processed the request. It is applied, as it should be...
    push(socket, @device_topic, "update", update_payload())
    assert_push(@device_topic, "status_update", %{status: :received})

    # ...and then the answer to the request arrives: refused, because the
    # manual push made the device busy.
    push(socket, @device_topic, "update_rejected", %{"reason" => "already_updating"})

    # The request was refused, so the caller must not be told it succeeded.
    refute Task.await(task) == :ok
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
      socket: [url: URI.parse("ws://localhost:4000/socket/websocket"), reconnect_after_msec: [1_000], test_mode?: true],
      ssl: []
    }

    start_supervised!(%{id: Socket, start: {Socket, :start_link, [config, [name: Socket]]}})
  end

  # See socket_messages_test.exs: the network interface probe calls
  # `:sys.get_state/1` on the connection process, which is this test.
  defp answer_network_interface_probe(timeout \\ 1_000) do
    receive do
      {:system, from, _request} -> GenServer.reply(from, {:ok, :no_connection_information})
    after
      timeout -> :ok
    end
  end

  defp update_payload do
    %{
      "firmware_url" => "http://localhost:4000/firmware.fw",
      "firmware_meta" => %{
        "uuid" => "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8",
        "product" => "test",
        "version" => "1.0.0",
        "platform" => "host",
        "architecture" => "x86_64"
      }
    }
  end
end
