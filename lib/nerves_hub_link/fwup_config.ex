# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.FwupConfig do
  @moduledoc """
  Manage Fwup config.
  """

  alias NervesHubLink.Configurator.Config

  @doc "Raises an ArgumentError on invalid arguments"
  @spec validate!(Config.t()) :: Config.t()
  def validate!(%Config{} = args) do
    args
    |> validate_fwup_devpath!()
    |> validate_fwup_task!()
    |> validate_fwup_env!()
  end

  defp validate_fwup_devpath!(%Config{fwup_devpath: devpath} = args) when is_binary(devpath),
    do: args

  defp validate_fwup_devpath!(%Config{}),
    do: raise(ArgumentError, message: "invalid arg: fwup_devpath")

  defp validate_fwup_task!(%Config{fwup_task: task} = args) when is_binary(task),
    do: args

  defp validate_fwup_task!(%Config{}),
    do: raise(ArgumentError, message: "invalid arg: fwup_task")

  defp validate_fwup_env!(%Config{fwup_env: list} = args) when is_list(list),
    do: args

  defp validate_fwup_env!(%Config{}),
    do: raise(ArgumentError, message: "invalid arg: fwup_env")
end
