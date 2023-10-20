["setup.exs"] |> Enum.map(&Code.require_file/1)

defmodule RendezvousWorker do
  use Ockam.Worker

  alias Ockam.Message
  alias Ockam.Router

  @impl true
  def setup(_options, state) do
    {:ok, Map.put(state, :client_info, %{})}
  end

  @impl true
  def handle_message(message, %{address: address} = state) do
    {reply_payload, state} = process_payload(message, state)

    message
    |> Message.reply(address, reply_payload)
    |> Router.route()

    {:ok, state}
  end

  defp process_payload(%{payload: "CONNECT " <> client_name} = message, state) do
    state =
      Map.update!(state, :client_info, fn client_info ->
        Map.put(client_info, client_name, find_public_address(message.return_route))
      end)

    {"CONNECTED", state}
  end

  defp process_payload(%{payload: "GET_ADDRESS " <> client_name}, state) do
    address = Map.get(state.client_info, client_name, "NOT_FOUND")
    {"ADDRESS #{address}", state}
  end

  defp process_payload(message, state) do
    IO.puts("Rendezvous received unexpected message: #{inspect(message)}")
    {"ADDRESS NOT_FOUND", state}
  end

  defp find_public_address(route) do
    Enum.find_value(route, fn step ->
      case step do
        %Ockam.Address{type: 2, value: value} -> value
        _ -> nil
      end
    end)
  end
end

defmodule RendezvousServer do
  use GenServer

  def start_link(port) do
    GenServer.start_link(__MODULE__, port)
  end

  def init(port) do
    {:ok, _listener} = Ockam.Transport.UDP.start(port: port)
    {:ok, _worker} = RendezvousWorker.create(address: "rendezvous")
    IO.puts("Rendezvous server started on port #{port}")
    {:ok, nil}
  end
end

defmodule Puncher do
  use GenServer

  alias Ockam.Transport.UDPAddress
  alias Ockam.Transport.UDP

  def start_link(this_name, that_name, rendezvous_ip, rendezvous_port, port, retry_interval) do
    GenServer.start_link(__MODULE__, %{
      this_name: this_name,
      that_name: that_name,
      rendezvous_address: UDPAddress.new(rendezvous_ip, rendezvous_port),
      port: port,
      retry_interval: retry_interval
    })
  end

  def init(args) do
    Ockam.Node.register_address(args.this_name)
    UDP.start(port: args.port)
    {:ok, args, {:continue, nil}}
  end

  def handle_continue(_, state) do
    send_message(state, "CONNECT #{state.this_name}")
    {:noreply, state}
  end

  def handle_info(%{payload: "CONNECTED"} = _message, state) do
    send_message(state, "GET_ADDRESS #{state.that_name}")
    {:noreply, state}
  end

  def handle_info(%{payload: "ADDRESS NOT_FOUND"} = _message, state) do
    :timer.sleep(state.retry_interval)
    send_message(state, "GET_ADDRESS #{state.that_name}")
    {:noreply, state}
  end

  def handle_info(%{payload: "ADDRESS " <> address} = _message, state) do
    IO.puts("Hole punched from #{state.this_name} to #{state.that_name} at #{address}")
    send_direct_messages(address, state.this_name, state.that_name)
    {:noreply, state}
  end

  def handle_info(%{payload: payload} = _message, state) do
    IO.puts("Received unexpected payload: #{inspect(payload)}")
    {:noreply, state}
  end

  defp send_direct_messages(address, this_name, that_name) do
    for num <- 0..5 do
      Ockam.Router.route(%{
        onward_route: [UDPAddress.new(address), that_name],
        return_route: [this_name],
        payload: "Message #{num} from #{this_name} to #{that_name}"
      })

      :timer.sleep(30)
    end
  end

  defp send_message(state, payload) do
    Ockam.Router.route(%{
      onward_route: [state.rendezvous_address, "rendezvous"],
      return_route: [state.this_name],
      payload: payload
    })
  end
end

# Start the Rendezvous server
RendezvousServer.start_link(4000)

# Start Alice, looking for Bob
Puncher.start_link("alice", "bob", "127.0.0.1", 4000, 3001, 100)

:timer.sleep(10)

# Start Bob, looking for Alice
Puncher.start_link("bob", "alice", "127.0.0.1", 4000, 3002, 100)

:timer.sleep(5000)
