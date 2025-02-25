defmodule ElixirLS.Debugger.ServerTest do
  # Awkwardly, testing that the debugger can debug ExUnit tests in the fixture project
  # gives us no way to capture the output, since ExUnit doesn't really distinguish
  # between the debugger's tests and the fixture project's tests. Expect to see output printed
  # from both.

  alias ElixirLS.Debugger.{Server, Protocol}
  use ElixirLS.Utils.MixTest.Case, async: false
  use Protocol

  doctest ElixirLS.Debugger.Server

  setup do
    {:ok, packet_capture} = ElixirLS.Utils.PacketCapture.start_link(self())
    Process.group_leader(Process.whereis(ElixirLS.Debugger.Output), packet_capture)

    {:ok, server} = Server.start_link()

    on_exit(fn ->
      for mod <- :int.interpreted(), do: :int.nn(mod)
      :int.auto_attach(false)
      :int.no_break()
      :int.clear()
    end)

    {:ok, %{server: server}}
  end

  describe "initialize" do
    test "succeeds", %{server: server} do
      Server.receive_packet(server, initialize_req(1, %{"clientID" => "some_id"}))
      assert_receive(response(_, 1, "initialize", %{"supportsConfigurationDoneRequest" => true}))
      assert :sys.get_state(server).client_info == %{"clientID" => "some_id"}
    end

    test "fails when already initialized", %{server: server} do
      Server.receive_packet(server, initialize_req(1, %{"clientID" => "some_id"}))
      assert_receive(response(_, 1, "initialize", %{"supportsConfigurationDoneRequest" => true}))
      Server.receive_packet(server, initialize_req(2, %{"clientID" => "some_id"}))

      assert_receive(
        error_response(
          _,
          2,
          "initialize",
          "invalidRequest",
          "Debugger request {command} was not expected",
          %{"command" => "initialize"}
        )
      )
    end

    test "rejects requests when not initialized", %{server: server} do
      Server.receive_packet(
        server,
        set_breakpoints_req(1, %{"path" => "lib/mix_project.ex"}, [%{"line" => 3}])
      )

      assert_receive(
        error_response(
          _,
          1,
          "setBreakpoints",
          "invalidRequest",
          "Debugger request {command} was not expected",
          %{"command" => "setBreakpoints"}
        )
      )
    end
  end

  describe "disconnect" do
    test "succeeds when not initialized", %{server: server} do
      Process.flag(:trap_exit, true)
      Server.receive_packet(server, request(1, "disconnect"))
      assert_receive(response(_, 1, "disconnect", %{}))
      assert_receive({:EXIT, ^server, {:exit_code, 0}})
      Process.flag(:trap_exit, false)
    end

    test "succeeds when initialized", %{server: server} do
      Process.flag(:trap_exit, true)
      Server.receive_packet(server, initialize_req(1, %{"clientID" => "some_id"}))
      assert_receive(response(_, 1, "initialize", %{"supportsConfigurationDoneRequest" => true}))
      Server.receive_packet(server, request(2, "disconnect"))
      assert_receive(response(_, 2, "disconnect", %{}))
      assert_receive({:EXIT, ^server, {:exit_code, 0}})
      Process.flag(:trap_exit, false)
    end
  end

  @tag :fixture
  test "basic debugging", %{server: server} do
    in_fixture(__DIR__, "mix_project", fn ->
      Server.receive_packet(server, initialize_req(1, %{}))
      assert_receive(response(_, 1, "initialize", %{"supportsConfigurationDoneRequest" => true}))

      Server.receive_packet(
        server,
        launch_req(2, %{
          "request" => "launch",
          "type" => "mix_task",
          "task" => "test",
          "taskArgs" => ["--only", "quadruple"],
          "projectDir" => File.cwd!()
        })
      )

      assert_receive(response(_, 2, "launch", %{}), 5000)
      assert_receive(event(_, "initialized", %{}))

      Server.receive_packet(
        server,
        set_breakpoints_req(3, %{"path" => "lib/mix_project.ex"}, [%{"line" => 3}])
      )

      assert_receive(
        response(_, 3, "setBreakpoints", %{"breakpoints" => [%{"verified" => true}]})
      )

      Server.receive_packet(server, request(4, "setExceptionBreakpoints", %{"filters" => []}))
      assert_receive(response(_, 4, "setExceptionBreakpoints", %{}))

      Server.receive_packet(server, request(5, "configurationDone", %{}))
      assert_receive(response(_, 5, "configurationDone", %{}))

      Server.receive_packet(server, request(6, "threads", %{}))
      assert_receive(response(_, 6, "threads", %{"threads" => threads}))
      # ensure thread ids are unique
      thread_ids = Enum.map(threads, & &1["id"])
      assert Enum.count(Enum.uniq(thread_ids)) == Enum.count(thread_ids)

      assert_receive event(_, "stopped", %{
                       "allThreadsStopped" => false,
                       "reason" => "breakpoint",
                       "threadId" => thread_id
                     }),
                     5_000

      Server.receive_packet(server, stacktrace_req(7, thread_id))

      assert_receive response(_, 7, "stackTrace", %{
                       "totalFrames" => 1,
                       "stackFrames" => [
                         %{
                           "column" => 0,
                           "id" => frame_id,
                           "line" => 3,
                           "name" => "MixProject.quadruple/1",
                           "source" => %{"path" => path}
                         }
                       ]
                     })
                     when is_integer(frame_id)

      assert String.ends_with?(path, "/lib/mix_project.ex")

      Server.receive_packet(server, scopes_req(8, frame_id))

      assert_receive response(_, 8, "scopes", %{
                       "scopes" => [
                         %{
                           "expensive" => false,
                           "indexedVariables" => 0,
                           "name" => "variables",
                           "namedVariables" => 1,
                           "variablesReference" => vars_id
                         },
                         %{
                           "expensive" => false,
                           "indexedVariables" => 1,
                           "name" => "arguments",
                           "namedVariables" => 0,
                           "variablesReference" => _
                         }
                       ]
                     })

      Server.receive_packet(server, vars_req(9, vars_id))

      assert_receive response(_, 9, "variables", %{
                       "variables" => [
                         %{
                           "name" => _,
                           "type" => "integer",
                           "value" => "2",
                           "variablesReference" => 0
                         }
                       ]
                     })

      Server.receive_packet(server, continue_req(10, thread_id))
      assert_receive response(_, 10, "continue", %{"allThreadsContinued" => false})
    end)
  end

  @tag :fixture
  test "handles invalid requests", %{server: server} do
    in_fixture(__DIR__, "mix_project", fn ->
      Server.receive_packet(server, initialize_req(1, %{}))
      assert_receive(response(_, 1, "initialize", %{"supportsConfigurationDoneRequest" => true}))

      Server.receive_packet(
        server,
        launch_req(2, %{
          "request" => "launch",
          "type" => "mix_task",
          "task" => "test",
          "projectDir" => File.cwd!()
        })
      )

      assert_receive(response(_, 2, "launch", %{}), 5000)
      assert_receive(event(_, "initialized", %{}))

      Server.receive_packet(
        server,
        set_breakpoints_req(3, %{"path" => "lib/mix_project.ex"}, [%{"line" => 3}])
      )

      assert_receive(
        response(_, 3, "setBreakpoints", %{"breakpoints" => [%{"verified" => true}]})
      )

      Server.receive_packet(server, request(4, "setExceptionBreakpoints", %{"filters" => []}))
      assert_receive(response(_, 4, "setExceptionBreakpoints", %{}))

      Server.receive_packet(server, request(5, "configurationDone", %{}))
      assert_receive(response(_, 5, "configurationDone", %{}))

      Server.receive_packet(server, request(6, "threads", %{}))
      assert_receive(response(_, 6, "threads", %{"threads" => threads}))
      # ensure thread ids are unique
      thread_ids = Enum.map(threads, & &1["id"])
      assert Enum.count(Enum.uniq(thread_ids)) == Enum.count(thread_ids)

      assert_receive event(_, "stopped", %{
                       "allThreadsStopped" => false,
                       "reason" => "breakpoint",
                       "threadId" => thread_id
                     }),
                     1_000

      Server.receive_packet(server, stacktrace_req(7, "not existing"))

      assert_receive error_response(
                       _,
                       7,
                       "stackTrace",
                       "invalidArgument",
                       "threadId not found: {threadId}",
                       %{"threadId" => "\"not existing\""}
                     )

      Server.receive_packet(server, scopes_req(8, "not existing"))

      assert_receive error_response(
                       _,
                       8,
                       "scopes",
                       "invalidArgument",
                       "frameId not found: {frameId}",
                       %{"frameId" => "\"not existing\""}
                     )

      Server.receive_packet(server, vars_req(9, "not existing"))

      assert_receive error_response(
                       _,
                       9,
                       "variables",
                       "invalidArgument",
                       "variablesReference not found: {variablesReference}",
                       %{"variablesReference" => "\"not existing\""}
                     )

      Server.receive_packet(server, next_req(10, "not existing"))

      assert_receive error_response(
                       _,
                       10,
                       "next",
                       "invalidArgument",
                       "threadId not found: {threadId}",
                       %{"threadId" => "\"not existing\""}
                     )

      Server.receive_packet(server, step_in_req(11, "not existing"))

      assert_receive error_response(
                       _,
                       11,
                       "stepIn",
                       "invalidArgument",
                       "threadId not found: {threadId}",
                       %{"threadId" => "\"not existing\""}
                     )

      Server.receive_packet(server, step_out_req(12, "not existing"))

      assert_receive error_response(
                       _,
                       12,
                       "stepOut",
                       "invalidArgument",
                       "threadId not found: {threadId}",
                       %{"threadId" => "\"not existing\""}
                     )

      Server.receive_packet(server, continue_req(13, "not existing"))

      assert_receive error_response(
                       _,
                       13,
                       "continue",
                       "invalidArgument",
                       "threadId not found: {threadId}",
                       %{"threadId" => "\"not existing\""}
                     )

      Server.receive_packet(server, request(14, "someRequest", %{"threadId" => 123}))

      assert_receive error_response(
                       _,
                       14,
                       "someRequest",
                       "notSupported",
                       "Debugger request {command} is currently not supported",
                       %{"command" => "someRequest"}
                     )

      Server.receive_packet(server, continue_req(15, thread_id))
      assert_receive response(_, 15, "continue", %{"allThreadsContinued" => false})

      Server.receive_packet(server, stacktrace_req(7, thread_id))
      thread_id_str = inspect(thread_id)

      assert_receive error_response(
                       _,
                       7,
                       "stackTrace",
                       "invalidArgument",
                       "process not paused: {threadId}",
                       %{"threadId" => ^thread_id_str}
                     )
    end)
  end

  @tag :fixture
  test "notifies about process exit", %{server: server} do
    in_fixture(__DIR__, "mix_project", fn ->
      Server.receive_packet(server, initialize_req(1, %{}))
      assert_receive(response(_, 1, "initialize", %{"supportsConfigurationDoneRequest" => true}))

      Server.receive_packet(
        server,
        launch_req(2, %{
          "request" => "launch",
          "type" => "mix_task",
          "task" => "run",
          "taskArgs" => ["-e", "MixProject.exit()"],
          "projectDir" => File.cwd!()
        })
      )

      assert_receive(response(_, 2, "launch", %{}), 5000)
      assert_receive(event(_, "initialized", %{}))

      Server.receive_packet(
        server,
        set_breakpoints_req(3, %{"path" => "lib/mix_project.ex"}, [%{"line" => 17}])
      )

      assert_receive(
        response(_, 3, "setBreakpoints", %{"breakpoints" => [%{"verified" => true}]}),
        1000
      )

      Server.receive_packet(server, request(4, "setExceptionBreakpoints", %{"filters" => []}))
      assert_receive(response(_, 4, "setExceptionBreakpoints", %{}))

      Server.receive_packet(server, request(5, "configurationDone", %{}))
      assert_receive(response(_, 5, "configurationDone", %{}))

      Server.receive_packet(server, request(6, "threads", %{}))
      assert_receive(response(_, 6, "threads", %{"threads" => threads}), 1_000)
      # ensure thread ids are unique
      thread_ids = Enum.map(threads, & &1["id"])
      assert Enum.count(Enum.uniq(thread_ids)) == Enum.count(thread_ids)

      assert_receive event(_, "stopped", %{
                       "allThreadsStopped" => false,
                       "reason" => "breakpoint",
                       "threadId" => thread_id
                     }),
                     500

      {log, stderr} =
        capture_log_and_io(:standard_error, fn ->
          assert_receive event(_, "thread", %{
                           "reason" => "exited",
                           "threadId" => ^thread_id
                         }),
                         5000
        end)

      assert log =~ "Fixture MixProject expected error"
      assert stderr =~ "Fixture MixProject expected error"
    end)
  end

  @tag :fixture
  test "notifies about mix task exit", %{server: server} do
    in_fixture(__DIR__, "mix_project", fn ->
      Server.receive_packet(server, initialize_req(1, %{}))
      assert_receive(response(_, 1, "initialize", %{"supportsConfigurationDoneRequest" => true}))

      Server.receive_packet(
        server,
        launch_req(2, %{
          "request" => "launch",
          "type" => "mix_task",
          "task" => "run",
          "taskArgs" => ["-e", "MixProject.exit_self()"],
          "projectDir" => File.cwd!()
        })
      )

      assert_receive(response(_, 2, "launch", %{}), 5000)
      assert_receive(event(_, "initialized", %{}))

      Server.receive_packet(
        server,
        set_breakpoints_req(3, %{"path" => "lib/mix_project.ex"}, [%{"line" => 29}])
      )

      assert_receive(
        response(_, 3, "setBreakpoints", %{"breakpoints" => [%{"verified" => true}]})
      )

      Server.receive_packet(server, request(4, "setExceptionBreakpoints", %{"filters" => []}))
      assert_receive(response(_, 4, "setExceptionBreakpoints", %{}))

      Server.receive_packet(server, request(5, "configurationDone", %{}))
      assert_receive(response(_, 5, "configurationDone", %{}))

      Server.receive_packet(server, request(6, "threads", %{}))
      assert_receive(response(_, 6, "threads", %{"threads" => threads}))
      # ensure thread ids are unique
      thread_ids = Enum.map(threads, & &1["id"])
      assert Enum.count(Enum.uniq(thread_ids)) == Enum.count(thread_ids)

      assert_receive event(_, "stopped", %{
                       "allThreadsStopped" => false,
                       "reason" => "breakpoint",
                       "threadId" => thread_id
                     }),
                     5000

      {log, io} =
        capture_log_and_io(:stderr, fn ->
          assert_receive event(_, "thread", %{
                           "reason" => "exited",
                           "threadId" => ^thread_id
                         }),
                         5000
        end)

      assert log =~ "Fixture MixProject raise for exit_self/0"
      assert io =~ "Fixture MixProject raise for exit_self/0"

      assert_receive event(_, "exited", %{
                       "exitCode" => 1
                     })

      assert_receive event(_, "terminated", %{
                       "restart" => false
                     })
    end)
  end

  @tag :fixture
  test "sets breakpoints in erlang modules", %{server: server} do
    in_fixture(__DIR__, "mix_project", fn ->
      Server.receive_packet(server, initialize_req(1, %{}))

      Server.receive_packet(
        server,
        launch_req(2, %{
          "request" => "launch",
          "type" => "mix_task",
          "task" => "test",
          "projectDir" => File.cwd!()
        })
      )

      Server.receive_packet(
        server,
        set_breakpoints_req(3, %{"path" => "src/hello.erl"}, [%{"line" => 5}])
      )

      assert_receive(
        response(_, 3, "setBreakpoints", %{"breakpoints" => [%{"verified" => true}]}),
        3000
      )

      assert(:hello in :int.interpreted())
    end)
  end

  describe "Watch section" do
    defp gen_watch_expression_packet(expr) do
      %{
        "arguments" => %{
          "context" => "watch",
          "expression" => expr,
          "frameId" => 123
        },
        "command" => "evaluate",
        "seq" => 1,
        "type" => "request"
      }
    end

    test "Evaluate expression with OK result", %{server: server} do
      Server.receive_packet(server, initialize_req(1, %{}))

      Server.receive_packet(
        server,
        gen_watch_expression_packet("1 + 2 + 3 + 4")
      )

      assert_receive(%{"body" => %{"result" => "10"}}, 1000)

      assert Process.alive?(server)
    end

    @tag :capture_log
    test "Evaluate expression with ERROR result", %{server: server} do
      Server.receive_packet(server, initialize_req(1, %{}))

      Server.receive_packet(
        server,
        gen_watch_expression_packet("1 = 2")
      )

      assert_receive(%{"body" => %{"result" => result}}, 1000)

      assert result =~ ~r/badmatch/

      assert Process.alive?(server)
    end

    test "Evaluate expression with attempt to exit debugger process", %{server: server} do
      Server.receive_packet(server, initialize_req(1, %{}))

      Server.receive_packet(
        server,
        gen_watch_expression_packet("Process.exit(self(), :normal)")
      )

      assert_receive(%{"body" => %{"result" => result}}, 1000)

      assert result =~ ~r/:exit/

      assert Process.alive?(server)
    end

    test "Evaluate expression with attempt to throw debugger process", %{server: server} do
      Server.receive_packet(server, initialize_req(1, %{}))

      Server.receive_packet(
        server,
        gen_watch_expression_packet("throw(:goodmorning_bug)")
      )

      assert_receive(%{"body" => %{"result" => result}}, 1000)

      assert result =~ ~r/:goodmorning_bug/

      assert Process.alive?(server)
    end

    test "Evaluate expression which has long execution", %{server: server} do
      Server.receive_packet(server, initialize_req(1, %{}))
      assert_receive(response(_, 1, "initialize", %{"supportsConfigurationDoneRequest" => true}))

      Server.receive_packet(
        server,
        launch_req(2, %{
          "request" => "launch",
          "type" => "mix_task",
          "task" => "test",
          "projectDir" => File.cwd!(),
          "debugExpressionTimeoutMs" => 500
        })
      )

      assert_receive(response(_, 2, "launch", %{}), 5000)

      Server.receive_packet(
        server,
        gen_watch_expression_packet(":timer.sleep(10_000)")
      )

      assert_receive(%{"body" => %{"result" => result}}, 1100)

      assert result =~ ~r/:elixir_ls_expression_timeout/

      assert Process.alive?(server)
    end
  end
end
