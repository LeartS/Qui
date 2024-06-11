defmodule Qui.JobQueue do
  @moduledoc """
  A simple job queue with support for different priorities and optional persistence.

  ## Jobs order
  Jobs are returned in (priority, FIFO) order.
  This means that higher priority jobs have precedence over lower precedence ones,
  independently of when they were enqueued.

  ## Persistence
  The JobQueue supports persistence to make it durable.
  To enable it, you can pass the `persistence_filename` option to `start_link/1`, e.g.

      {:ok, queue} = JobQueue.start_link(persistence_filename: "/tmp/queue.dat")

  will start a JobQueue which persists the jobs to `/tmp/queue.dat`.
  Make sure the directory exists, as the JobQueue will not create it for you.

  Note that the persistance mechanism is :dets based, and currently it flushes to disk
  on every `enqueue`/`dequeue` operation, which can have a noticeable performance impact.

  ## Usage
  You can use the JobQueue directly by using its `enqueue/2` and `dequeue/1` APIs,
  but for most job handling scenarios you'll probably want to use a pool of `Qui.Worker`
  supervised by a `Qui.WorkerSupervisor`. By doing so, you'll get a system which
  automatically handles polling the queue, error management, handling retries,
  job processing timeouts, restarting crashed workers, etc. etc.
  """
  use GenServer
  require Logger
  alias UUID
  alias Qui.Job

  # Currently we hardcode just two priorities,
  # but the code has been generalized a little bit to make it
  # easier to implement more priorities or even potentially
  # allow the priorities to be specified per queue at runtime.
  @type priority() :: :low | :high
  @type queues() :: %{priority() => :queue.queue(Job.t())}

  @typedoc """
  The internal state of the JobQueue GenServer

  * `queues`: a map of queues, one per priority.
    we use separate internal queues to avoid having to traverse a single queue
    to find jobs with the highest priority.
  * `dets_table`: the :dets table onto which jobs are persisted, if the `JobQueue`
    was started with persistance enabled.
  """
  @type state() :: %{
          queues: queues(),
          dets_table: :dets.tab_name() | nil
        }
  @type enqueue_option() ::
          {:priority, priority()}
          | {:max_retries, non_neg_integer()}
          | {:retry_delay, non_neg_integer()}
          | {:timeout, non_neg_integer()}

  @default_job_options [priority: :low, max_retries: 3, retry_delay: 100, timeout: 60_000]
  @ordered_priorities [:high, :low]

  @impl GenServer
  def init(queue_opts) do
    case queue_opts[:persistence_filename] do
      nil ->
        {:ok, %{queues: empty_queues(), dets_table: nil}}

      filename when is_binary(filename) ->
        {:ok, table} = :dets.open_file(String.to_charlist(filename), type: :set)
        queues = load_from_storage(table)
        {:ok, %{queues: queues, dets_table: table}}
    end
  end

  @impl GenServer
  def handle_call({:enqueue, %Job{} = job} = op, _from, state) do
    new_state = update_in(state, [:queues, job.priority], &:queue.in(job, &1))
    :ok = maybe_persist(op, state.dets_table)

    Logger.info(
      "New job in JobQueue #{inspect(self())}: job id: #{job.id}, job task: #{inspect(job.task)}"
    )

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:dequeue, {caller, _} = _from, %{queues: queues} = state) do
    case highest_priority_with_jobs(queues) do
      # All queues are empty
      nil ->
        {:reply, :empty, state}

      priority ->
        {{:value, job}, tail} = queues |> Map.fetch!(priority) |> :queue.out()
        :ok = maybe_persist({:dequeue, job}, state.dets_table)

        Logger.debug(
          "Job #{job.id} has been sent to #{inspect(caller)} and removed from JobQueue #{inspect(self())}"
        )

        {:reply, job, put_in(state, [:queues, priority], tail)}
    end
  end

  @impl GenServer
  def handle_info(unknown_message, state) do
    Logger.warning("Queue #{inspect(self())} got unexpected info #{inspect(unknown_message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("JobQueue #{inspect(self())} terminating (#{inspect(reason)})..")

    case state.dets_table do
      nil -> :ok
      table -> :dets.close(table)
    end
  end

  def start_link(opts \\ []) do
    queue_opts = Keyword.take(opts, [:persistence_filename])

    case opts[:name] do
      nil -> GenServer.start_link(__MODULE__, queue_opts)
      name -> GenServer.start_link(__MODULE__, queue_opts, name: name)
    end
  end

  @doc """
  Creates a `Qui.Job` from a task definition, and adds it to the queue.

  Returns the `Qui.Job`.

  ## Options

    * `max_retries`: how many times the job will be retried before
       giving up and marking the job as permanently failed.
       Defaults to `3`.

    * `:retry_delay` - minimum delay, in milliseconds, between job retries in case of failure.
      Note that is a _minimum_ delay because if the worker is busy processing some other job,
      the failed job might be reattempted a bit later.
      The delay is fixed per-job: every retry on that job will have the same delay,
      at the moment smarter strategies like exponential backoff are not supported.
      Defaults to 100ms.

    * `:priority`: the priority of the job.
      Jobs with higher priority will always be executed before jobs with a lower one,
      independently of when they were pushed to the queue.
      Defaults to `:low`.

    * `:timeout`: timeout for job processing, in milliseconds.
      If job processing takes longer than this, the processor will be shut down,
      and the job attempt treated as failed and retried with the usual logic.
      You can use the special value `:infinity` to let the job processing run indefinitely.
      Defaults to 60 seconds.

  """
  @spec enqueue(GenServer.server(), term()) :: Job.t()
  @spec enqueue(GenServer.server(), term(), [enqueue_option()]) :: Job.t()
  def enqueue(queue, task, opts \\ []) do
    opts = Keyword.merge(@default_job_options, opts)

    job = %Job{
      id: UUID.uuid4(),
      task: task,
      attempts: 0,
      priority: Keyword.fetch!(opts, :priority),
      max_retries: Keyword.fetch!(opts, :max_retries),
      retry_delay: Keyword.fetch!(opts, :retry_delay),
      timeout: Keyword.fetch!(opts, :timeout),
      enqueued_at: DateTime.utc_now()
    }

    # We use `call` instead of `cast` for consistency and durability reason:
    # we return to the caller only when we're sure the job has been added to the queue
    # (and persisted to disk if persistance is enabled)
    GenServer.call(queue, {:enqueue, job})
    job
  end

  @doc """
  Returns the first job to be processed, in (priority, FIFO) order.

  Returns `:empty` if there are no jobs in the queue.
  """
  @spec dequeue(GenServer.server()) :: :empty | Job.t()
  def dequeue(queue) do
    case GenServer.call(queue, :dequeue) do
      :empty -> :empty
      job -> job
    end
  end

  @doc """
  Returns the highest priority key which has a non-empty queue.

  Returns `nil` if all queues are empty.
  """
  @spec highest_priority_with_jobs(queues()) :: priority() | nil
  def highest_priority_with_jobs(queues) do
    Enum.find(@ordered_priorities, fn priority ->
      queues
      |> Map.fetch!(priority)
      |> :queue.peek()
      |> case do
        :empty -> false
        {:value, _val} -> true
      end
    end)
  end

  @spec load_from_storage(:dets.tab_name()) :: queues()
  defp load_from_storage(table) do
    Logger.info("Loading JobQueue jobs from storage (storage_key: #{table}}")

    objs = :dets.select(table, [{{:"$1", :"$2"}, [], [:"$2"]}])

    queues =
      objs
      |> Enum.group_by(fn job -> job.priority end)
      |> Enum.map(fn {priority, jobs} ->
        queue =
          jobs
          |> Enum.sort_by(fn job -> job.enqueued_at end, DateTime)
          |> :queue.from_list()

        {priority, queue}
      end)
      |> Enum.into(%{})

    Logger.info("Loaded #{length(objs)} jobs from storage")

    # We merge with an empty_queues() map to make sure we initialize
    # a queue for each supported priority, independently of the priorities
    # of the jobs saved on disk.
    Map.merge(empty_queues(), queues)
  end

  defp maybe_persist(_, nil), do: :ok

  defp maybe_persist({:enqueue, job}, table) do
    :dets.insert(table, {job.id, job})
    # TODO: this might be overkill and cause performance issues, re-evaluate
    :dets.sync(table)
  end

  defp maybe_persist({:dequeue, job}, table) do
    :dets.delete(table, job.id)
    # TODO: this might be overkill and cause performance issues, re-evaluate
    :dets.sync(table)
  end

  defp empty_queues() do
    Enum.into(@ordered_priorities, %{}, fn priority -> {priority, :queue.new()} end)
  end
end
