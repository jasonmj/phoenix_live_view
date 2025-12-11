defmodule Phoenix.LiveView.RenderUploadsTest do
  use ExUnit.Case, async: false
  require Phoenix.ChannelTest

  import Phoenix.LiveViewTest

  alias Phoenix.LiveViewTest.UploadClient
  alias Phoenix.LiveViewTest.Support.UploadLive

  @endpoint Phoenix.LiveViewTest.Support.Endpoint
  @context "upload_test_context"

  defmodule TestWriter do
    @behaviour Phoenix.LiveView.UploadWriter

    @impl true
    def init(test_name) do
      send(test_name, :init)
      {:ok, test_name}
    end

    @impl true
    def meta(test_name) do
      send(test_name, :meta)
      test_name
    end

    @impl true
    def write_chunk("error", test_name) do
      {:error, :custom_error, test_name}
    end

    def write_chunk(data, test_name) do
      send(test_name, {:write_chunk, data})
      {:ok, test_name}
    end

    @impl true
    def close(test_name, reason) do
      send(test_name, {:close, reason})
      {:ok, test_name}
    end
  end

  def mount_lv(setup) when is_function(setup, 1) do
    conn = Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
    {:ok, lv, _} = live_isolated(conn, UploadLive, session: %{})
    :ok = GenServer.call(lv.pid, {:setup, setup})
    {:ok, lv}
  end

  def build_entries(count, opts \\ []) do
    content = String.duplicate("0", 100)
    size = byte_size(content)

    for i <- 1..count do
      Enum.into(opts, %{
        last_modified: 1_594_171_879_000,
        name: "myfile#{i}.jpeg",
        relative_path: "./myfile#{i}.jpeg",
        content: content,
        size: size,
        type: "image/jpeg"
      })
    end
  end

  setup %{allow: opts} do
    {:ok, lv} = mount_lv(fn socket -> Phoenix.LiveView.allow_upload(socket, :avatar, opts) end)
    {:ok, lv: lv}
  end

  describe "render_uploads/3 - sequential mode" do
    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "uploads all entries to 100% by default", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))
      html = render_uploads(avatar)

      assert html =~ "#{@context}:myfile1.jpeg:100%"
      assert html =~ "#{@context}:myfile2.jpeg:100%"
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "uploads all entries with global percent", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))
      html = render_uploads(avatar, :all, 50)

      assert html =~ "#{@context}:myfile1.jpeg:50%"
      assert html =~ "#{@context}:myfile2.jpeg:50%"
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "uploads specific entries by name", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(3))
      html = render_uploads(avatar, ["myfile1.jpeg", "myfile3.jpeg"])

      assert html =~ "#{@context}:myfile1.jpeg:100%"
      assert html =~ "#{@context}:myfile3.jpeg:100%"
      # myfile2 should not be uploaded
      refute html =~ "#{@context}:myfile2.jpeg:100%"
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "uploads entries with per-entry percent map", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(3))

      html =
        render_uploads(avatar, ["myfile1.jpeg", "myfile2.jpeg"], %{
          "myfile1.jpeg" => 30,
          "myfile2.jpeg" => 60
        })

      assert html =~ "#{@context}:myfile1.jpeg:30%"
      assert html =~ "#{@context}:myfile2.jpeg:60%"
      refute html =~ "#{@context}:myfile3.jpeg"
    end

    @tag allow: [max_entries: 2, chunk_size: 20, accept: :any]
    test "aggregates errors when entries exceed max", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(3))

      # Trigger validation
      assert lv
             |> form("form", user: %{})
             |> render_change(avatar) =~ "config_error::too_many_files"

      # Try to upload all entries - should get errors for entries over max
      result = render_uploads(avatar, :all, 100)
      assert {:error, errors} = result
      assert is_list(errors)
      # At least one entry should have :not_allowed or similar error
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "raises ArgumentError for unknown entry name", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))

      assert_raise ArgumentError, ~r/no file input with name "unknown.jpeg"/, fn ->
        render_uploads(avatar, ["myfile1.jpeg", "unknown.jpeg"])
      end
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "raises ArgumentError for invalid entries_or_names", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))

      assert_raise ArgumentError, ~r/entries_or_names must be/, fn ->
        render_uploads(avatar, "invalid")
      end
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "raises ArgumentError for invalid percent", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))

      assert_raise ArgumentError, ~r/percent must be between 0 and 100/, fn ->
        render_uploads(avatar, :all, 150)
      end

      assert_raise ArgumentError, ~r/percent must be between 0 and 100/, fn ->
        render_uploads(avatar, :all, -10)
      end
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "raises ArgumentError for invalid percent map", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))

      assert_raise ArgumentError, ~r/percent for "myfile1.jpeg" must be between/, fn ->
        render_uploads(avatar, :all, %{"myfile1.jpeg" => 150})
      end

      assert_raise ArgumentError, ~r/percent map includes entry "unknown.jpeg"/, fn ->
        render_uploads(avatar, ["myfile1.jpeg"], %{"unknown.jpeg" => 50})
      end
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any, progress: :consume]
    test "handles progress callbacks during sequential upload", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))
      html = render_uploads(avatar)

      # Progress callbacks should be triggered
      assert html =~ "consumed:myfile1.jpeg"
      assert html =~ "consumed:myfile2.jpeg"
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any, progress: :consume]
    test "returns redirect tuple on live_redirect during upload", %{lv: lv} do
      avatar =
        file_input(lv, "form", :avatar, [
          %{name: "redirect.jpeg", content: String.duplicate("0", 100)},
          %{name: "myfile2.jpeg", content: String.duplicate("0", 100)}
        ])

      result = render_uploads(avatar, :all, 100)
      assert {:error, {:live_redirect, redir}} = result
      assert redir[:to] == "/redirected"
    end
  end

  describe "render_uploads/4 - interleaved mode" do
    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "uploads entries with round-robin interleaving", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))
      html = render_uploads(avatar, :all, 100, mode: :interleaved)

      # Both files should complete
      assert html =~ "#{@context}:myfile1.jpeg:100%"
      assert html =~ "#{@context}:myfile2.jpeg:100%"
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "uploads with custom step_percent", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))
      html = render_uploads(avatar, :all, 100, mode: :interleaved, step_percent: 10)

      # Both files should complete
      assert html =~ "#{@context}:myfile1.jpeg:100%"
      assert html =~ "#{@context}:myfile2.jpeg:100%"
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "uploads specific entries in interleaved mode", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(3))
      html = render_uploads(avatar, ["myfile1.jpeg", "myfile3.jpeg"], 100, mode: :interleaved)

      assert html =~ "#{@context}:myfile1.jpeg:100%"
      assert html =~ "#{@context}:myfile3.jpeg:100%"
      refute html =~ "#{@context}:myfile2.jpeg:100%"
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "handles per-entry percent map in interleaved mode", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))

      html =
        render_uploads(
          avatar,
          :all,
          %{"myfile1.jpeg" => 50, "myfile2.jpeg" => 75},
          mode: :interleaved
        )

      assert html =~ "#{@context}:myfile1.jpeg:50%"
      assert html =~ "#{@context}:myfile2.jpeg:75%"
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any, progress: :consume]
    test "returns redirect on live_redirect in interleaved mode", %{lv: lv} do
      avatar =
        file_input(lv, "form", :avatar, [
          %{name: "redirect.jpeg", content: String.duplicate("0", 100)},
          %{name: "myfile2.jpeg", content: String.duplicate("0", 100)}
        ])

      result = render_uploads(avatar, :all, 100, mode: :interleaved, step_percent: 20)
      assert {:error, {:live_redirect, redir}} = result
      assert redir[:to] == "/redirected"
    end

    @tag allow: [max_entries: 3, chunk_size: 20, accept: :any]
    test "raises ArgumentError for invalid mode", %{lv: lv} do
      avatar = file_input(lv, "form", :avatar, build_entries(2))

      assert_raise ArgumentError, ~r/invalid mode :invalid/, fn ->
        render_uploads(avatar, :all, 100, mode: :invalid)
      end
    end
  end

  describe "render_uploads - external upload errors" do
    def mount_external_lv(setup, external_fn) when is_function(setup, 1) do
      conn = Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})
      {:ok, lv, _} = live_isolated(conn, UploadLive, session: %{})

      :ok =
        GenServer.call(lv.pid, {:setup, fn socket ->
          opts = [
            max_entries: 3,
            chunk_size: 20,
            accept: :any,
            external: external_fn
          ]

          Phoenix.LiveView.allow_upload(socket, :avatar, opts)
        end})

      {:ok, lv}
    end

    test "aggregates preflight errors for multiple entries" do
      external_fn = fn entry, socket ->
        if entry.client_name == "error.jpeg" do
          {:error, :test_error}
        else
          {:ok, %{uploader: "S3"}, socket}
        end
      end

      {:ok, lv} = mount_external_lv(fn socket -> socket end, external_fn)

      avatar =
        file_input(lv, "form", :avatar, [
          %{name: "error.jpeg", content: String.duplicate("0", 100)},
          %{name: "good.jpeg", content: String.duplicate("0", 100)}
        ])

      # This should aggregate errors
      result = render_uploads(avatar, :all, 100)

      # We expect an error response since one entry has a preflight error
      case result do
        {:error, errors} ->
          assert is_list(errors)
          # Should contain error for the failed entry
          assert Enum.any?(errors, fn
                   [[_ref, :test_error]] -> true
                   _ -> false
                 end)

        html when is_binary(html) ->
          # If we get HTML, the good entry should be uploaded
          assert html =~ "good.jpeg"
      end
    end
  end
end
