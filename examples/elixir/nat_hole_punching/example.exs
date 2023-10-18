["setup.exs"] |> Enum.map(&Code.require_file/1)

defmodule RendezvousServer do
  use GenServer

  def start_link(port) do
    GenServer.start_link(__MODULE__, port)
  end

  def init(port) do
    {:ok, socket} = :gen_udp.open(port, [:binary, {:active, true}])
    IO.puts("SERVER: Rendezvous server started on port #{port}")
    {:ok, {socket, %{}}}
  end

  def handle_info({:udp, _socket, {ip1, ip2, ip3, ip4} = ip_tuple, port, message}, {socket, state}) do
    ip = "#{ip1}.#{ip2}.#{ip3}.#{ip4}"
    IO.puts("SERVER: Received message from #{ip}:#{port}: #{message}")

    state =
      case String.split(message, " ") do
        ["CONNECT", client_name] ->
          {:ok, updated_state} = store_client_info(client_name, ip, port, state)
          reply_to_client(socket, ip_tuple, port, "CONNECTED")
          updated_state

        ["GET_ADDRESS", client_name] ->
          ip = Map.get(state, client_name, "MISSING")
          reply_to_client(socket, ip_tuple, port, "ADDRESS #{ip}")
          state

        _ ->
          IO.puts("SERVER: Received unexpected message: #{message}")
          state
      end

    {:noreply, {socket, state}}
  end

  defp reply_to_client(socket, ip, port, message) do
    :gen_udp.send(socket, ip, port, message)
  end

  defp store_client_info(client_name, client_ip, client_port, state) do
    {:ok, Map.put(state, client_name, "#{client_ip}:#{client_port}")}
  end
end

defmodule RendezvousClient do
  use GenServer

  # Replace with the IP address of your Rendezvous server
  @server_ip {127, 0, 0, 1}

  # Replace with the UDP port of your Rendezvous server
  @server_port 4000

  def start_link(this_name, that_name) do
    GenServer.start_link(__MODULE__, %{this_name: this_name, that_name: that_name})
  end

  def init(args) do
    {:ok, socket} = :gen_udp.open(0, [:binary])
    {:ok, {socket, args}, {:continue, nil}}
  end

  def handle_continue(_, {socket, %{this_name: this_name} = args}) do
    register_this(socket, this_name)
    {:noreply, {socket, args}}
  end

  defp register_this(socket, this_name) do
    IO.puts("CLIENT: Registering #{this_name}")
    connect_message = "CONNECT #{this_name}"
    send_message(socket, connect_message)
  end

  defp wait_for_hole(socket, that_name) do
    IO.puts("CLIENT: Waiting for hole to be punched")
    send_message(socket, "GET_ADDRESS #{that_name}")
  end

  defp send_message(socket, message) do
    :gen_udp.send(socket, @server_ip, @server_port, message)
  end

  def handle_info({:udp, _socket, _ip, _port, "CONNECTED"}, {socket, %{that_name: that_name} = state}) do
    IO.puts("CLIENT: Connected, requesting #{that_name} info")
    wait_for_hole(socket, that_name)
    {:noreply, {socket, state}}
  end

  def handle_info({:udp, _socket, _ip, _port, "ADDRESS MISSING"}, {socket, %{that_name: that_name} = state}) do
    :timer.sleep(100)
    wait_for_hole(socket, that_name)
    {:noreply, {socket, state}}
  end

  def handle_info({:udp, _socket, _ip, _port, "ADDRESS " <> ip}, {socket, %{this_name: this_name, that_name: that_name} = state}) do
    IO.puts("CLIENT: Hole punched #{that_name} - #{ip}")
    regex = ~r|(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}):(\d{1,5})|
    results = Regex.run(regex, ip)
    [_, ip1, ip2, ip3, ip4, that_port] = Enum.map(results, fn num ->
      {int, _} = Integer.parse(num)
      int
    end)

    that_ip = {ip1, ip2, ip3, ip4}

    for num <- 0..9 do
      :gen_udp.send(socket, that_ip, that_port,  "Message #{num} from #{this_name} to #{that_name}")
    end

    #:gen_udp.close(socket)

    {:noreply, {socket, state}}
  end

  def handle_info({:udp, _socket, _ip, _port, message}, {socket, state}) do
    IO.puts("CLIENT: received #{message}")
    {:noreply, {socket, state}}
  end
end

# Start the Rendezvous server
RendezvousServer.start_link(4000)

:timer.sleep(100)

# Start Alice
RendezvousClient.start_link("alice", "bob")

:timer.sleep(100)

# Start Bob
RendezvousClient.start_link("bob", "alice")
