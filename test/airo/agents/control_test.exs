defmodule Airo.Agents.ControlTest do
  # async: false — some tests toggle the global `:airo, :agent_token`.
  use ExUnit.Case, async: false

  alias Airo.Agents.Control
  alias Airo.Config.Agent

  defp agent(fields \\ []) do
    struct(%Agent{host_id: "jobycorp", control_url: "http://jobycorp:4400"}, fields)
  end

  defp opts, do: [req_options: [plug: {Req.Test, __MODULE__}]]

  describe "inventory/2" do
    test "returns the models list and hits GET /inventory" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:req, conn.method, conn.request_path})

        Req.Test.json(conn, %{
          "models" => [%{"id" => "unsloth/Qwen3.6-35B", "revision" => "abc123"}]
        })
      end)

      assert {:ok, [%{"id" => "unsloth/Qwen3.6-35B", "revision" => "abc123"}]} =
               Control.inventory(agent(), opts())

      assert_received {:req, "GET", "/inventory"}
    end

    test "maps a non-2xx to {:error, {:http_error, status, reason}}" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:http_error, 500, "boom"}} = Control.inventory(agent(), opts())
    end
  end

  describe "telemetry span (S25)" do
    test "wraps every control call with host_id, op and the response status" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:airo, :agent, :control, :start],
          [:airo, :agent, :control, :stop]
        ])

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"models" => []}) end)
      assert {:ok, []} = Control.inventory(agent(), opts())

      assert_received {[:airo, :agent, :control, :start], ^ref, _,
                       %{host_id: "jobycorp", op: :inventory}}

      assert_received {[:airo, :agent, :control, :stop], ^ref, %{duration: _},
                       %{host_id: "jobycorp", op: :inventory, status: 200}}
    end

    test "names the load op and reports a refused connection as a transport error" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:airo, :agent, :control, :stop]])

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, {:transport_error, _}} = Control.load(agent(), 8081, "m", opts())

      assert_received {[:airo, :agent, :control, :stop], ^ref, _,
                       %{op: :load, status: :transport_error}}
    end
  end

  describe "observer guard (S26)" do
    test "load and unload are refused for an observer without touching the network" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:req, conn.request_path})
        Req.Test.json(conn, %{})
      end)

      observer = agent(role: :observer)

      assert {:error, :observer_role} = Control.load(observer, 8081, "m", opts())
      assert {:error, :observer_role} = Control.unload(observer, 8081, opts())
      refute_received {:req, _}

      # Reads and the idempotent rescan still go through.
      assert {:ok, _} = Control.inventory(observer, opts())
      assert {:ok, _} = Control.refresh_inventory(observer, opts())
      assert_received {:req, "/inventory"}
      assert_received {:req, "/inventory/refresh"}
    end

    test "a controller is unaffected" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"port" => 8081}) end)
      assert :accepted = Control.load(agent(role: :controller), 8081, "m", opts())
      assert :accepted = Control.unload(agent(), 8081, opts())
    end
  end

  describe "load/4" do
    test "posts {model, slot} to /load and returns :accepted" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:load, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"port" => 8081, "status" => "loading"})
      end)

      assert :accepted = Control.load(agent(), 8081, "unsloth/Qwen3.6-35B", opts())
      assert_received {:load, "/load", %{"model" => "unsloth/Qwen3.6-35B", "slot" => 8081}}
    end

    test "sends a launch profile and drops nil values" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:load, Jason.decode!(body)})
        Req.Test.json(conn, %{"status" => "loading"})
      end)

      assert :accepted =
               Control.load(
                 agent(),
                 8081,
                 "m",
                 Keyword.put(opts(), :profile, %{ctx: 65_536, parallel: nil})
               )

      assert_received {:load, %{"profile" => %{"ctx" => 65_536} = profile}}
      refute Map.has_key?(profile, "parallel")
    end

    test "an empty profile is omitted (agent default)" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:load, Jason.decode!(body)})
        Req.Test.json(conn, %{"status" => "loading"})
      end)

      assert :accepted =
               Control.load(agent(), 8081, "m", Keyword.put(opts(), :profile, %{ctx: nil}))

      assert_received {:load, body}
      refute Map.has_key?(body, "profile")
    end

    test "404 → {:error, {:unknown_model, id}}" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "unknown model"})
      end)

      assert {:error, {:unknown_model, "ghost"}} = Control.load(agent(), 8081, "ghost", opts())
    end

    test "422 → {:error, {:rejected, status, reason}}" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "no VRAM"})
      end)

      assert {:error, {:rejected, 422, "no VRAM"}} =
               Control.load(agent(), 8081, "unsloth/Qwen3.6-35B", opts())
    end
  end

  describe "unload/3" do
    test "posts {slot} to /unload and returns :accepted" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:unload, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert :accepted = Control.unload(agent(), 8081, opts())
      assert_received {:unload, "/unload", %{"slot" => 8081}}
    end
  end

  describe "errors" do
    test "a missing control_url short-circuits without a request" do
      assert {:error, :no_control_url} = Control.inventory(agent(control_url: nil), opts())
    end

    test "a transport failure maps to {:error, {:transport_error, _}}" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, {:transport_error, _}} = Control.inventory(agent(), opts())
    end
  end

  describe "auth" do
    test "sends the shared bearer when :agent_token is set" do
      prior = Application.get_env(:airo, :agent_token)
      Application.put_env(:airo, :agent_token, "s3cr3t")
      on_exit(fn -> Application.put_env(:airo, :agent_token, prior) end)

      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"models" => []})
      end)

      assert {:ok, []} = Control.inventory(agent(), opts())
      assert_received {:auth, ["Bearer s3cr3t"]}
    end
  end
end
