defmodule Qui.Worker do
  @moduledoc """
  Generic `Qui.JobQueue` worker

  Workers are responsible for interacting with a`Qui.JobQueue`,
  automatically fetching and processing jobs, including error handling and retries.
  The actual processing logic is delegated to the processing which is passed at initialization.
  The processing function should be synchronous/blocking,
  you should use a worker pool to provide concurrency in a controlled and scalable way.

  You can start a worker process manually, but it is recommended to start a pool
  of workers at application startup using the dynamic supervisor `Qui.WorkerSupervisor`.
  (see its documentation for examples).
  """
  use GenServer
  require Logger

  alias Qui.Job
  alias Qui.JobQueue

  @typedoc """
  The type of the underlying function responsible for the job processing logic.
  The function should be synchronous, making it easy to implement and reason about,
  leaving concurrency cocnerns to the worker pool.
  """
  @type processor_function() :: (Job.t() -> {:ok, term()} | {:error, Exception.t()})

  @impl GenServer
  def init({queue, process_fn}) do
    Logger.info("Worker #{inspect(self())} init")
    {:ok, %{queue: queue, process_fn: process_fn}, {:continue, :start_loop}}
  end

  @impl GenServer
  def handle_continue(:start_loop, state) do
    Logger.metadata(worker_pid: self(), worker_queue: state.queue)
    Logger.info("Worker #{inspect(self())} starting up")
    Process.send_after(self(), :loop, 1)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:loop, %{queue: queue, process_fn: process_fn} = state) do
    case JobQueue.dequeue(queue) do
      :empty ->
        # JobQueue is empty, check again in a couple of milliseconds
        # to avoid spamming it with useless deque requests
        Process.send_after(self(), :loop, 2)

      job ->
        process_job(process_fn, job)
        send(self(), :loop)
    end

    {:noreply, state}
  end

  def handle_info({:retry, job}, %{process_fn: process_fn} = state) do
    process_job(process_fn, job)
    {:noreply, state}
  end

  def handle_info(unknown_message, state) do
    Logger.warning("Queue #{inspect(self())} got unexpected info #{inspect(unknown_message)}")
    {:noreply, state}
  end

  def start_link({queue, process_fn}) do
    {:ok, _pid} = GenServer.start_link(__MODULE__, {queue, process_fn})
  end

  defp process_job(process_fn, %Job{id: job_id} = job) do
    Logger.info(
      "Worker #{inspect(self())} starting processing job #{job_id} (attempt #{job.attempts + 1})"
    )

    processing_task =
      Task.async(fn ->
        try do
          process_fn.(job)
        rescue
          # Catch uncaught exceptions and treat them as if the processor
          # returned an {:error, exception} value
          exception -> {:error, exception}
        end
      end)

    # It is usually not recommended to block on tasks in a GenServer,
    # but in this case it's fine,
    # as each worker is supposed to be working on a single task at any give time.
    case Task.yield(processing_task, job.timeout) || Task.shutdown(processing_task) do
      {:ok, {:ok, _res}} ->
        Logger.info("Worker #{inspect(self())} successfully processed job #{job_id}")
        :ok

      {:ok, {:error, error}} ->
        handle_error(error, job)

      nil ->
        handle_error(:timeout, job)
    end
  end

  @spec handle_error(Exception.t() | :timeout, Job.t()) :: :ok
  def handle_error(error, job)

  def handle_error(error, %Job{attempts: attempts, max_retries: max_retries} = job)
      when attempts < max_retries do
    Logger.error([
      "Job #{job.id} failed with error #{format_error(error)}",
      ", retrying in #{job.retry_delay}ms",
      " (attempt #{job.attempts + 1} of #{job.max_retries + 1})"
    ])

    Process.send_after(self(), {:retry, %Job{job | attempts: attempts + 1}}, job.retry_delay)
    :ok
  end

  def handle_error(error, %Job{} = job) do
    Logger.error([
      "Job #{job.id} failed with error #{format_error(error)}",
      ", reached maximum number of attempts (#{job.max_retries + 1})."
    ])

    :ok
  end

  defp format_error(error) when is_exception(error) do
    Exception.message(error)
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: inspect(error)
end
