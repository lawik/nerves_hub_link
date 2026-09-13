# SPDX-FileCopyrightText: 2020 Jacob Arellano
# SPDX-FileCopyrightText: 2020 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ConfiguratorTest do
  use ExUnit.Case, async: true

  test "inserts socket_opts from ssl" do
    ssl = [
      versions: [:"tlsv1.2"],
      cert: "ima cert!",
      key: "ima key!",
      cacerts: ["Everyone", "gets", "a", "CA"],
      server_name_indication: "what_is_up",
      verify: :verify_peer
    ]

    config = NervesHubLink.Configurator.build()
    assert config.socket[:transport_opts][:socket_opts] == ssl
  end

  test "fwup_version is included in params" do
    config = NervesHubLink.Configurator.build()
    assert Map.has_key?(config.params, "fwup_version")
  end

  test "only includes binary in fwup_public_keys" do
    keys = [
      # cspell:disable-next-line
      "thisisavalidkey==",
      :not_valid,
      false,
      {:also, :not, :valid},
      nil,
      1234
    ]

    Application.put_env(:nerves_hub_link, :fwup_public_keys, keys)

    config = NervesHubLink.Configurator.build()

    # cspell:disable-next-line
    assert ["thisisavalidkey=="] == config.fwup_public_keys
  end
end

defmodule NervesHubLink.ConfiguratorOverridesTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Configurator

  test "build/1 signs an overridden shared secret into the headers" do
    config =
      Configurator.build(
        instance: 42,
        configurator: NervesHubLink.Configurator.SharedSecret,
        shared_secret: [product_key: "nhp_key", product_secret: "secret", identifier: "vd-42"],
        params: %{"nerves_fw_uuid" => "override-uuid"}
      )

    assert config.instance == 42
    assert config.params["nerves_fw_uuid"] == "override-uuid"
    assert config.shared_secret[:identifier] == "vd-42"

    headers = Map.new(config.socket[:headers])
    assert headers["x-nh-key"] == "nhp_key"
    assert is_binary(headers["x-nh-signature"])
  end

  test "build/0 is build/1 with nothing overridden" do
    assert Configurator.build().instance == NervesHubLink.Instance.default()
  end
end
