# Some tests start second Erlang nodes to try the multi-machine path.
# That needs the name server (epmd); without it those tests skip.
distributed =
  case System.cmd("epmd", ["-daemon"], stderr_to_stdout: true) do
    {_, 0} ->
      match?({:ok, _}, Node.start(:"stress_test_main@127.0.0.1", :longnames))

    _ ->
      false
  end

ExUnit.start(exclude: if(distributed, do: [], else: [:distributed]))
