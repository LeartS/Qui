defmodule Qui.WorkerSupervisor do
  @moduledoc """
  A DynamicSupervisor for `Qui.Worker` instances.

  Batch of workers can be started using `start_workers/1` and,
  because this is a `DynamicSupervisor`, you can use the `DynamicSupervisor`
  APIs to start/stop/observe worker instances.

  Because DynamicSupervisor does not support an initial list of children,
  (see https://elixirforum.com/t/understanding-dynamicsupervisor-no-initial-children/14938)
  you have to add Qui.WorkerSupervisor with no children to your application supervision tree,
  and then use `start_workers/1` on application startup to add some workers.

  Note that at the moment there's no support for automatically scaling the number of workers
  based on load on the queue. You can do so manually by connecting to the remote shell.
  """
  use DynamicSupervisor

  alias Qui.Worker

  @type workers_batch() :: {GenServer.server(), Worker.processor_function(), pos_integer()}

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(init_arg) do
    DynamicSupervisor.init(init_arg)
  end

  @doc """
  Starts batches of workers.

  Each worker batch is a tuple of `{queue, processor, count}`, where:
  * `queue` is the queue process (can be a pid or a registered name)
  * `processor` is the processor function
  * `count` is how many such workers should be created

  So, for example, if you pass the following:

      [
        {MyApp.MainQueue, fn _job -> {:ok, "noop processor"} end, 5},
        {MyApp.SecondaryQueue, fn _job -> {:ok, "noop processor"} end, 2}
      ]

  The supervisor will start 5 workers consuming from the queue named MyApp.MainQueue,
  and 2 workers consuming from MyApp.SecondaryQueue.
  """
  @spec start_workers([workers_batch()]) :: :ok
  def start_workers(workers_batches) do
    for {queue, processor, count} <- workers_batches, _i <- 1..count do
      {:ok, _child_pid} =
        DynamicSupervisor.start_child(__MODULE__, {Qui.Worker, {queue, processor}})
    end

    :ok
  end
end
