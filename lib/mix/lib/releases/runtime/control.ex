defmodule Mix.Releases.Runtime.Control do
  @moduledoc """
  This module defines the tooling for interacting with nodes, as well
  as other utiltiy functions of use.
  """
  use Artificery

  require Record

  rec = Record.extract(:etop_proc_info, from_lib: "runtime_tools/include/observer_backend.hrl")
  Record.defrecordp(:etop_proc_info, rec)

  alias Artificery.Console

  defoption :name, :string, 
    "The name of the remote node to connect to.\n" <>
    "Can be in either long form (i.e. 'foo@bar') or short form (i.e. 'foo')"
    
  defoption :cookie, :string,
    "The distribution cookie to use when connecting to peers",
    transform: &String.to_atom/1

  option :verbose, :boolean, "Turns on verbose output", alias: :v

  # Basic management tasks
  command :ping, "Pings the remote node" do
    option :cookie, required: true
    option :peer, :string, "The node name of the peer to ping"
  end

  # Stub for `describe`
  command :start, "Starts the remote node"

  command :stop, "Stops the remote node" do
    option :name
    option :cookie
  end

  command :restart, "Restarts the remote node. This will not restart the emulator" do
    option :name
    option :cookie
  end

  command :reboot, "Reboots the remote node. This will restart the emulator" do
    option :name
    option :cookie
  end

  # Stub for `describe`
  command :attach, "Attach directly to the remote node's console"

  # Stub for `describe`
  command :remote_console, "Connect to the remote node via remote shell"

  # Stub for `describe`
  command :foreground, "Run the release in the foreground"

  # Upgrade management tasks
  command :unpack, "Unpacks a release upgrade for installation" do
    option :name
    option :cookie
    option :release, :string, "The release name", required: true, hidden: true

    argument :version, :string, "The release version to unpack", required: true
  end

  command :install, "Installs a release upgrade" do
    option :name
    option :cookie
    option :release, :string, "The release name", required: true, hidden: true

    argument :version, :string, "The release version to install", required: true
  end

  # Configuration tasks
  command :reload_config, "Reloads the config of the remote node" do
    option :name
    option :cookie
    option :sysconfig, :string, "The path to a sys.config file"
  end

  command :rpc, "Executes the provided expression on the remote node" do
    option :name
    option :cookie
    option :file, :string, "Evaluate a file instead of an expression"

    argument :expr, :string, "The expression to evaluate", required: true
  end

  command(:eval, "Executes the provided expression in a clean node") do
    option :file, :string, "Evaluate a file instead of an expression"
    argument :expr, :string, "The expression to evaluate"
  end

  command :escript, "Executes the given escript" do
    argument :path, :string, "The path to the escript to execute"
  end

  command :info, "Prints information about the remote node to stdout" do
    option :name
    option :cookie

    command :processes, [callback: :processes_info], "Show a table of running processes" do
      option :sort_by, :string,
        "Sets the sort column (default: memory)\n" <>
        "Valid types are: reductions, memory, message_queue, name, current_function, pid",
        transform: :to_process_info_sort_by
    end
  end

  command :describe, "Describes the currently installed release" do
    option :name
    option :cookie
    option :release_root_dir, :string, "The root directory for all releases"
    option :sysconfig, :string, "The path to the sys.config file used by the release"
    option :vmargs, :string, "The path to the vm.args file used by the release"
    option :config, :string, "The path to the config.exs file used by the release"
    option :erl_opts, :string, "Extra options for erl"
    option :run_erl_env, :string, "Extra configuration for run_erl"
  end

  @doc """
  This function executes before any commands are dispatched
  """
  @impl Artificery
  def pre_dispatch(_cmd, _argv, %{name: name, cookie: cookie} = opts) do
    # If required, it means we need to connect to the remote node
    {:ok, peer, name, type} = start_distribution!(name, cookie)

    new_opts =
      opts
      |> Map.put(:name, name)
      |> Map.put(:peer, peer)
      |> Map.put(:name_type, type)

    {:ok, new_opts}
  end

  def pre_dispatch(cmd, argv, %{peer: peer} = opts) do
    pre_dispatch(cmd, argv, Map.put(opts, :name, peer))
  end

  def pre_dispatch(_cmd, _argv, opts), do: {:ok, opts}

  ## Commands

  defp format_os({:unix, name}) do
    name =
      name
      |> Atom.to_string
      |> String.capitalize
    "#{name} " <> format_os_version(:os.version)
  end
  defp format_os({:win32, _}) do
    "Windows " <> format_os_version(:os.version)
  end

  defp format_os_version({maj, min, patch}) do
    "#{maj}.#{min}.#{patch}"
  end
  defp format_os_version(vsn) when is_list(vsn) do
    List.to_string(vsn)
  end

  defp format_status(%{peer: peer}) do
    case hidden_connect(peer) do
      {:ok, _} ->
        "running"
      _ ->
        "stopped"
    end
  end

  @doc """
  Describes the current release
  """
  def describe(_argv, opts) do
    Console.debug "Gathering release description.."
    start_data = start_data(opts)
    opts = Map.put(opts, :version, start_data.version)
    Console.success "#{opts.release}-#{start_data.version}"
    Console.info "System Info ==========================="
    Console.info "OS:     #{format_os(:os.type)}"
    Console.info "ERTS:   #{start_data.erts}"
    status = format_status(opts)
    if status == "running" do
      IO.write ["Status: ", IO.ANSI.bright, IO.ANSI.green, status, IO.ANSI.reset, ?\n]
    else
      IO.write ["Status: ", IO.ANSI.yellow, status, IO.ANSI.reset, ?\n]
    end

    Console.info "Release Info =========================="
    Console.info "Name:              #{opts.name}"
    Console.info "Cookie:            #{opts.cookie}"
    Console.info "Working Directory: #{opts.release_root_dir}"
    Console.info "System Config:     #{opts.sysconfig}"
    Console.info "VM Config:         #{opts.vmargs}"
    Console.info "App Config:        #{opts.config}"
    Console.info "Extra Erl Flags:   #{opts.erl_opts || "N/A"}"
    Console.info "Run Erl Env:       #{opts.run_erl_env || "N/A"}\n"

    Console.info "Hooks ================================="
    for {group, hooks} <- fetch_hooks(opts) do
      Console.info "#{group}:"
      if length(hooks) > 0 do
        {hook_width, doc_width} = column_widths(hooks)
        for {hook, doc} <- hooks do
          IO.write([hook, String.duplicate(" ", max(hook_width - byte_size(hook) + 2, 2))])
          print_help_lines(doc, doc_width + 1)
        end
      else
        Console.warn "    No #{group} hooks defined"
      end
    end

    Console.info "Custom Commands ======================="
    custom_commands = fetch_custom_commands(opts)
    if length(custom_commands) > 0 do
      {command_width, doc_width} = column_widths(custom_commands)
      for {name, doc} <- fetch_custom_commands(opts) do
        IO.write([name, String.duplicate(" ", max(command_width - byte_size(name) + 2, 2))])
        print_help_lines(doc, doc_width + 2)
      end
    else
      Console.warn "No custom commands defined"
    end
  end

  defp start_data(%{release_root_dir: root_dir}) do
    [erts, version] =
      Path.join([root_dir, "releases", "start_erl.data"])
      |> File.read!
      |> String.split(" ", parts: 2)
    erts_vsn =
      case erts do
        "ERTS_VSN" ->
          # Get host ERTS version
          List.to_string(:erlang.system_info(:version))
        erts_vsn ->
          erts_vsn
      end
    %{erts: erts_vsn, version: version}
  end

  defp fetch_hooks(%{release_root_dir: root_dir, version: version}) do
    hook_types = Path.join([root_dir, "releases", version, "hooks", "*.d"])
    for hook_type <- Path.wildcard(hook_types), into: %{} do
      hooks =
        hook_type
        |> File.ls!
        |> Enum.map(fn hook_file ->
            {hook_file, read_doc(Path.join(hook_type, hook_file))}
          end)
      {hook_type, hooks}
    end
  end

  defp fetch_custom_commands(%{release_root_dir: root_dir, version: version}) do
    commands =
      Path.join([root_dir, "releases", version, "commands", "*"])
      |> Path.wildcard
    for command <- commands do
      ext = Path.extname(command)
      name = Path.basename(command, ext)
      doc = read_doc(command)
      {name, doc}
    end
  end

  defp read_doc(path) do
    path
    |> File.stream!([:read], :line)
    |> Stream.reject(fn "#!" <> _shebang -> true; _ -> false  end)
    |> Stream.take_while(fn <<c::utf8, _doc::binary>> when c in [?\#, ?%] -> true; _ -> false end)
    |> Stream.map(fn line ->
      line |> String.replace(~r/^[#%]+/, "") |> String.trim
    end)
    |> Enum.join(" ")
  end

  @doc """
  Prints information about a remote node.
  """
  def processes_info(_argv, %{peer: peer} = opts) do
    # Connect to remote
    hidden_connect!(peer)
    Console.info("Connected to peer..")
    check_runtime_tools!(peer)
    print_processes_info(peer, opts)
  end

  defp print_processes_info(peer, opts) do
    parent = self()

    task =
      Task.async(fn ->
        case :rpc.call(peer, :observer_backend, :procs_info, [self()]) do
          {:badrpc, reason} ->
            send(parent, {:badrpc, reason})

          _result ->
            procs = get_process_infos(opts)
            header = ["Name", "PID", "Current Fun", "Reductions", "Memory", "Message Q"]
            Console.Table.print("Processes", header, procs)
            send(parent, :ok)
        end
      end)

    case Task.await(task, :infinity) do
      {:badrpc, reason} ->
        Console.error("Failed during remote call with: #{inspect(reason)}")

      :ok ->
        :ok
    end
  end

  defp get_process_infos(opts) when is_map(opts) do
    sort_field = Map.get(opts, :sort_by, :mem)

    sorter = fn proc ->
      {Keyword.get(proc, sort_field), Keyword.get(proc, :name)}
    end

    collect_etop_proc_infos()
    |> Enum.map(fn p -> etop_proc_info(p) end)
    |> Enum.sort_by(sorter)
    |> Enum.map(&format_process_info/1)
  end

  defp collect_etop_proc_infos(acc \\ []) do
    receive do
      {:procs_info, _pid, processes} ->
        len = length(processes)

        if len < 10_000 do
          acc ++ processes
        else
          collect_etop_proc_infos(acc ++ processes)
        end
    end
  end

  defp format_process_info(proc) when is_list(proc) do
    case proc[:name] do
      n when is_atom(n) ->
        [n, "#{inspect(proc[:pid])}", format_mfa(proc[:cf]), proc[:reds], proc[:mem], proc[:mq]]

      {_m, _f, _a} = start_mfa ->
        [
          format_mfa(start_mfa),
          "#{inspect(proc[:pid])}",
          format_mfa(proc[:cf]),
          proc[:reds],
          proc[:mem],
          proc[:mq]
        ]
    end
  end

  defp format_mfa({m, f, a}), do: "#{m}.#{f}/#{a}"

  @doc """
  Pings a peer node.
  """
  def ping(_args, %{peer: peer}) do
    case hidden_connect(peer) do
      {:ok, :pong} ->
        Console.info("pong")

      {:error, :pang} ->
        failed_connect!(peer)
    end
  end

  @doc """
  Stops a peer node
  """
  def stop(_args, %{peer: peer}) do
    hidden_connect!(peer)
    _ = :rpc.call(peer, :init, :stop, [], 60_000)
    Console.info("ok")
  end

  @doc """
  Restarts a peer node (this is a soft restart, emulator is left up)
  """
  def restart(_args, %{peer: peer}) do
    hidden_connect!(peer)
    _ = :rpc.call(peer, :init, :restart, [], 60_000)
    Console.info("ok")
  end

  @doc """
  Reboots a peer node (this is a hard restart, emulator is restarted)
  """
  def reboot(_args, %{peer: peer}) do
    hidden_connect!(peer)
    _ = :rpc.call(peer, :init, :reboot, [], 60_000)
    Console.info("ok")
  end

  @doc """
  Applies any pending configuration changes in config files to a peer node.
  """
  def reload_config(_argv, %{peer: peer} = opts) do
    sysconfig =
      case Map.get(opts, :sysconfig) do
        nil ->
          []

        path ->
          case :file.consult(String.to_charlist(path)) do
            {:error, reason} ->
              Console.error("Unable to read sys.config from #{path}: #{inspect(reason)}")

            {:ok, [config]} ->
              config
          end
      end

    has_sysconfig? = length(sysconfig)

    case rpc_call(peer, :application_controller, :prep_config_change) do
      {:badrpc, reason} ->
        Console.error("Unable to prepare config change, call failed: #{inspect(reason)}")

      oldenv ->

        if has_sysconfig? do
          Console.info("Applying sys.config...")

          for {app, config} <- sysconfig do
            Console.debug("Updating #{app}..")

            for {key, value} <- config do
              Console.debug("  #{app}.#{key} = #{inspect(value)}")

              case rpc_call(peer, :application, :set_env, [app, key, value, [persistent: true]]) do
                {:badrpc, reason} ->
                  Console.error("Failed during call to :application.set_env/4: #{inspect(reason)}")

                _ ->
                  :ok
              end
            end
          end
        end

        providers =
          case Keyword.get(sysconfig, :distillery) do
            nil ->
              Console.debug("Trying to fetch config providers from peer..")
              case rpc_call(peer, :application, :get_env, [:distillery, :config_providers]) do
                {:badrpc, reason} ->
                  Console.error("Failed to fetch provider configuration from remote: #{inspect(reason)}")
                providers when is_list(providers) ->
                  providers

                _ ->
                  []
              end
            opts ->
              Keyword.get(opts, :config_providers, [])
          end

        if length(providers) == 0 do
          Console.debug("No config providers defined, skipping..")
        else
          Console.debug("Running config providers..")
          case rpc_call(peer, Mix.Releases.Config.Provider, :init, [providers], :infinity) do
            {:badrpc, reason} ->
              Console.error("Failed to run config providers: #{inspect(reason)}")

            _ ->
              Console.debug("Config providers executed successfully!")
          end
        end

        Console.debug "Applying config change via :application_controller.."
        case rpc_call(peer, :application_controller, :config_change, [oldenv]) do
          {:badrpc, reason} ->
            Console.error("Failed during :application_controller.config_change/1: #{inspect(reason)}")

          _ ->
            Console.success("Config changes applied successfully!")
        end
    end
  end

  @doc """
  Executes an expression or a file on a remote node.
  """
  def rpc(argv, %{file: file} = opts) do
    case File.read(file) do
      {:ok, contents} ->
        rpc(argv, opts |> Map.delete(:file) |> Map.put(:expr, contents))

      {:error, reason} ->
        Console.error "Failed to read #{file}: #{inspect reason}"
    end
  end
  def rpc(_argv, %{expr: expr, peer: peer}) do
    case Code.string_to_quoted(expr) do
      {:ok, quoted} ->
        case rpc_call(peer, Code, :eval_quoted, [quoted], :infinity) do
          {:badrpc, {:EXIT, {type, trace}}} ->
            Console.error """
            Given the following expression: #{Macro.to_string(quoted)}

            The remote call failed with:

            #{Exception.format(:exit, type, trace)}
            """
          {:badrpc, {kind, {type, trace}}} when kind in [:exit, :throw, :error] ->
            Console.error """
            Given the following expression: #{Macro.to_string(quoted)}

            The remote call failed with:

            #{Exception.format(kind, type, trace)}
            """
          {:badrpc, reason} ->
            Console.error("Remote call failed with: #{inspect(reason)}")

          {result, _bindings} ->
            IO.inspect(result)
        end

      {:error, {_line, error, token}} when is_binary(error) and is_binary(token) ->
        Console.error("Invalid expression: #{error <> token}")

      {:error, {_line, error, _}} ->
        Console.error("Invalid expression: #{inspect(error)}")
    end
  end

  def rpc(_argv, %{peer: _}) do
    Console.error("You must provide an Elixir expression to 'rpc'")
  end

  @doc """
  Executes an expression or a file locally (i.e. not on the running node)
  """
  def eval(_argv, %{file: file}) do
    Code.eval_file(file)
  rescue
    err in [Code.LoadError] ->
      Console.error """
      Could not load #{Path.expand(file)}: #{Exception.message(err)}

      #{Exception.format_stacktrace(err)}
      """
    err ->
      Console.error """
      Evaluation failed: #{Exception.message(err)}

      #{Exception.format_stacktrace(err)}
      """
  end
  def eval(_argv, %{expr: expr}) do
    case Code.string_to_quoted(expr) do
      {:ok, quoted} ->
        try do
          Code.eval_quoted(quoted)
        rescue
          err ->
            Console.error("Evaluation failed with: " <> Exception.message(err))
        end

      {:error, {_line, error, token}} when is_binary(error) and is_binary(token) ->
        Console.error("Invalid expression: #{error <> token}")

      {:error, {_line, error, _}} ->
        Console.error("Invalid expression: #{inspect(error)}")
    end
  end

  def eval([], _opts) do
    Console.error("You must provide an Elixir expression to 'eval'")
  end

  @doc """
  Unpacks a release in preparation for it to be loaded
  """
  def unpack(_argv, %{peer: peer, release: release, version: version}) do
    unless is_binary(release) and is_binary(version) do
      Console.error("You must provide both --release and --version to 'unpack_release'")
    end

    releases = which_releases(release, peer)

    case List.keyfind(releases, version, 0) do
      nil ->
        # Not installed, so unpack tarball
        Console.info(
          "Release #{release}:#{version} not found, attempting to unpack releases/#{version}/#{
            release
          }.tar.gz"
        )

        package = version |> Path.join(release) |> String.to_charlist()

        case rpc_call(peer, :release_handler, :unpack_release, [package], :infinity) do
          {:badrpc, reason} ->
            Console.error("Unable to unpack release, call failed with: #{inspect(reason)}")

          {:ok, vsn} ->
            Console.success("Unpacked #{inspect(vsn)} successfully!")

          {:error, reason} ->
            Console.warn("Installed versions:")

            for {version, status} <- releases do
              Console.warn("  * #{version}\t#{status}")
            end

            Console.error("Unpack failed with: #{inspect(reason)}")
        end

      {_ver, reason} when reason in [:old, :unpacked, :current, :permanent] ->
        # Already unpacked
        Console.warn("Release #{release}:#{version} is already unpacked!")
    end
  end

  @doc """
  Installs a release, unpacking if necessary
  """
  def install(_argv, %{peer: peer, release: release, version: version}) do
    unless is_binary(release) and is_binary(version) do
      Console.error("You must provide both --release and --version to 'install_release'")
    end

    releases = which_releases(release, peer)

    case List.keyfind(releases, version, 0) do
      nil ->
        # Not installed, so unpack tarball
        Console.info(
          "Release #{release}:#{version} not found, attempting to unpack releases/#{version}/#{
            release
          }.tar.gz"
        )

        package = Path.join(version, release)

        case rpc_call(peer, :release_handler, :unpack_release, [package], :infinity) do
          {:badrpc, reason} ->
            Console.error("Failed during remote call with: #{inspect(reason)}")

          {:ok, _} ->
            Console.info("Unpacked #{version} successfully!")
            install_and_permafy(peer, release, version)

          {:error, reason} ->
            Console.warn("Installed versions:")

            for {vsn, status} <- releases do
              Console.warn("  * #{vsn}\t#{status}")
            end

            Console.error("Unpack failed with: #{inspect(reason)}")
        end

      {_ver, :old} ->
        Console.info("Release #{release}:#{version} is marked old, switching to it..")
        install_and_permafy(peer, release, version)

      {_ver, :unpacked} ->
        Console.info("Release #{release}:#{version} is already unpacked, installing..")
        install_and_permafy(peer, release, version)

      {_ver, :current} ->
        Console.info(
          "Release #{release}:#{version} is already installed and current, making permanent.."
        )

        permafy(peer, release, version)

      {_ver, :permanent} ->
        Console.info("Release #{release}:#{version} is already installed, current, and permanent!")
    end
  end

  @doc false
  def start_distribution!(name, cookie) do
    {peer, name, type} =
      case Regex.split(~r/@/, name) do
        [sname] ->
          {String.to_atom(sname), String.to_atom("#{sname}_maint_"), :shortnames}

        [sname, host] ->
          {String.to_atom("#{sname}@#{host}"), String.to_atom("#{sname}_maint_@#{host}"),
           :longnames}

        _parts ->
          Console.error("Invalid --name value: #{name}")
      end

    start_epmd()

    case :net_kernel.start([name, type]) do
      {:ok, _} ->
        Node.set_cookie(cookie)
        :ok

      {:error, {:already_started, _}} ->
        Node.set_cookie(cookie)
        :ok

      {:error, reason} ->
        Console.error("Could not start distribution: #{inspect(reason)}")
    end

    {:ok, peer, name, type}
  end

  ## Helpers

  defp rpc_call(peer, m, f, a \\ [], timeout \\ 60_000) do
    :rpc.call(peer, m, f, a, timeout)
  end

  defp failed_connect!(peer) do
    Console.error("""
    Received 'pang' from #{peer}!
    Possible reasons for this include:
      - The cookie is mismatched between us and the target node
      - We cannot establish a remote connection to the node
    """)
  end

  defp hidden_connect!(target) do
    case hidden_connect(target) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        failed_connect!(target)
    end
  end

  defp hidden_connect(target) do
    case :net_kernel.hidden_connect_node(target) do
      true ->
        case :net_adm.ping(target) do
          :pong ->
            {:ok, :pong}

          :pang ->
            {:error, :pang}
        end

      _ ->
        {:error, :pang}
    end
  end

  defp start_epmd() do
    System.cmd(epmd(), ["-daemon"])
    :ok
  end

  defp epmd() do
    case System.find_executable("epmd") do
      nil ->
        Console.error("Unable to locate epmd!")

      path ->
        path
    end
  end

  defp install_and_permafy(peer, release, version) do
    vsn = String.to_charlist(version)

    case rpc_call(peer, :release_handler, :check_install_release, [vsn], :infinity) do
      {:badrpc, reason} ->
        Console.error("Failed during remote call with: #{inspect(reason)}")

      {:ok, _other_vsn, _desc} ->
        :ok

      {:error, reason} ->
        Console.error(
          "Release handler check for #{release}:#{version} failed with: #{inspect(reason)}"
        )
    end

    case rpc_call(
           peer,
           :release_handler,
           :install_release,
           [vsn, [update_paths: true]],
           :infinity
         ) do
      {:badrpc, reason} ->
        Console.error("Failed during remote call with: #{inspect(reason)}")

      {:ok, _, _} ->
        Console.info("Installed release #{release}:#{version}")
        update_config(peer)
        permafy(peer, release, version)
        :ok

      {:error, {:no_such_release, ^vsn}} ->
        Console.warn("Installed versions:")

        for {vsn, status} <- which_releases(release, peer) do
          Console.warn("  * #{vsn}\t#{status}")
        end

        Console.error("Unable to revert to #{version}: not installed")

      {:error, {:old_processes, mod}} ->
        # As described in http://erlang.org/doc/man/appup.html
        # When executing a relup containing soft_purge instructions:
        #   If the value is soft_purge, release_handler:install_release/1
        #   returns {:error, {:old_processes, mod}}
        Console.error("Unable to install #{version}: old processes still running code from #{mod}")

      {:error, reason} ->
        Console.error("Release handler failed to install: #{inspect(reason)}")
    end
  end

  defp permafy(peer, release, version) do
    case rpc_call(
           peer,
           :release_handler,
           :make_permanent,
           [String.to_charlist(version)],
           :infinity
         ) do
      {:badrpc, reason} ->
        Console.error("Failed during remote call with: #{inspect(reason)}")

      :ok ->
        File.cp(Path.join("bin", "#{release}-#{version}"), Path.join("bin", release))
        Console.info("Made release #{release}:#{version} permanent")
    end
  end

  defp update_config(peer) do
    Console.info("Updating config..")

    with {:ok, providers} <-
           rpc_call(peer, :application, :get_env, [:distillery, :config_providers]),
         oldenv <- rpc_call(peer, :application_controller, :prep_config_change),
         _ <- rpc_call(peer, Mix.Releases.Config.Provider, :init, [providers], :infinity),
         _ <- rpc_call(peer, :application_controller, :config_change, [oldenv]) do
      :ok
    else
      {:badrpc, reason} ->
        Console.error("Failed during remote call with: #{inspect(reason)}")

      :undefined ->
        Console.info("No config providers, skipping config update")
        # No config providers
        :ok
    end
  end

  defp which_releases(name, peer) do
    case rpc_call(peer, :release_handler, :which_releases, [], :infinity) do
      {:badrpc, reason} ->
        Console.error("Failed to interrogate release information from #{peer}: #{inspect(reason)}")

      releases ->
        name = String.to_charlist(name)

        releases
        |> Enum.filter(fn {n, _, _, _} -> n == name end)
        |> Enum.map(fn {_, version, _, status} -> {List.to_string(version), status} end)
    end
  end

  # Ensures runtime_tools is present on the remote node
  defp check_runtime_tools!(peer) do
    # Check for runtime tools
    case :rpc.call(peer, :erlang, :function_exported, [:observer_backend, :module_info, 0]) do
      {:badrpc, reason} ->
        Console.error("Failed during remote call with: #{inspect(reason)}")

      false ->
        Console.error("Runtime tools unavailable on the remote node!")

      _ ->
        Console.info("Runtime tools detected, requesting info..")
        :ok
    end
  end

  @doc false
  def to_process_info_sort_by("reductions"), do: :reds
  def to_process_info_sort_by("memory"), do: :mem
  def to_process_info_sort_by("message_queue"), do: :mq
  def to_process_info_sort_by("name"), do: :name
  def to_process_info_sort_by("current_function"), do: :cf
  def to_process_info_sort_by("pid"), do: :pid

  def to_process_info_sort_by(other) do
    Console.warn("Invalid --sort-by (#{other}), ignoring..")
    :mem
  end
end
