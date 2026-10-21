defmodule StressTester.Profile do
  @moduledoc "The target behind a run. The runner does not know the protocol."

  @callback prepare(map) :: map
  @callback plan(map) :: list
  @callback open(map, term) :: map
  @callback close(map) :: term
  @callback drive(map, map) :: map
  @callback expect(list) :: map
  @callback auth_rejected?(map) :: boolean
  @callback reconnect?(map) :: boolean
  @callback ok?(map) :: boolean
end
