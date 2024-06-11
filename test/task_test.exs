defmodule Qui.TaskTest do
  use ExUnit.Case

  alias Qui.Job
  alias Qui.JobQueue
  alias Qui.Task
  alias Qui.Worker

  def send_arg_to_pid(pid) do
    fn arg -> send(pid, arg) end
  end

  defmodule SendJobToPID do
    @moduledoc """
    A `Qui.Task` which sends the job to the pid specified in the task params
    """
    @behaviour Task

    @enforce_keys [:pid, :message_key]
    defstruct [:pid, :message_key]

    @type t() :: %__MODULE__{
            pid: pid(),
            message_key: atom()
          }

    @impl Task
    def perform(%Job{task: %__MODULE__{pid: pid, message_key: message_key}} = job) do
      send(pid, {message_key, job})
      :ok
    end
  end

  test "process/1 dispatches the job to the right callback module" do
    {:ok, q} = JobQueue.start_link()
    {:ok, _worker_pid} = Worker.start_link({q, &Task.process/1})

    task = %SendJobToPID{
      pid: self(),
      message_key: :processed
    }

    job = JobQueue.enqueue(q, task)
    assert_receive {:processed, ^job}, 10
  end
end
