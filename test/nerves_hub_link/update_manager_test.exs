# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Frank Hunleth
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManagerTest do
  use ExUnit.Case
  alias NervesHubLink.UpdateManager
  alias NervesHubLink.Message.{FirmwareMetadata, UpdateInfo}
  alias NervesHubLink.Support.{FWUPStreamPlug, Utils}

  describe "fwup stream" do
    setup do
      config = default_config()
      port = Utils.unique_port_number()

      update_payload = %UpdateInfo{
        firmware_url: "http://localhost:#{port}/test.fw",
        firmware_meta: %FirmwareMetadata{}
      }

      {:ok, plug} =
        start_supervised(
          {Plug.Cowboy, scheme: :http, plug: FWUPStreamPlug, options: [port: port]}
        )

      File.rm(config.fwup_devpath)

      {:ok, [plug: plug, update_payload: update_payload, config: config]}
    end

    test "apply", %{update_payload: update_payload, config: config} do
      {:ok, manager} = UpdateManager.start_link(config)
      assert UpdateManager.apply_update(manager, update_payload, []) == :updating

      assert_receive {:fwup, {:progress, 0}}
      assert_receive {:fwup, {:progress, 100}}
      assert_receive {:fwup, {:ok, 0, ""}}
    end

    test "reschedule", %{update_payload: update_payload, config: config} do
      test_pid = self()

      #Mox.expect(ClientMock, :update_available, fn _ ->
      #  case Process.get(:reschedule) do
      #    nil ->
      #      send(test_pid, :rescheduled)
      #      Process.put(:reschedule, true)
      #      {:reschedule, 50}
      #
      #    _ ->
      #      :apply
      #  end
      #end)

      {:ok, manager} = UpdateManager.start_link(config)
      assert UpdateManager.apply_update(manager, update_payload, []) == :update_rescheduled
      assert_received :rescheduled
      refute_received {:fwup, _}

      assert_receive {:fwup, {:progress, 0}}, 250
      assert_receive {:fwup, {:progress, 100}}
      assert_receive {:fwup, {:ok, 0, ""}}
    end

    test "apply with fwup environment", %{update_payload: update_payload, config: config} do
      config = %{config |
          fwup_task: "secret_upgrade",
          fwup_env: [
            {"SUPER_SECRET", "1234567890123456789012345678901234567890123456789012345678901234"}
          ]
      }

      # If setting SUPER_SECRET in the environment doesn't happen, then test fails
      # due to fwup getting a bad aes key.
      #Mox.expect(ClientMock, :update_available, fn _ -> :apply end)
      #Mox.expect(ClientMock, :reboot, fn -> :ok end)
      {:ok, manager} = UpdateManager.start_link(config)
      assert UpdateManager.apply_update(manager, update_payload, []) == :updating

      assert_receive {:fwup, {:progress, 0}}
      assert_receive {:fwup, {:progress, 100}}
      assert_receive {:fwup, {:ok, 0, ""}}
    end
  end

  defp default_config() do
    %{NervesHubLink.Configurator.build() | fwup_devpath: "/tmp/fwup_output", }
  end
end
