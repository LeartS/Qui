defmodule Qui.Task do
  @moduledoc """
  A behaviour structured tasks with a default processor dispatching logic

  For example, you could implement different callback modules like this:

     defmodule Tasks.SendSMS do
       require Logger
       @behaviour Qui.Task

       @enforce_keys [:to, :content]
       defstruct [:to, :content]

       @type t() :: %__MODULE__{
               to: String.t(),
               content: String.t()
             }

       @impl Task
       def perform(%Job{task: %__MODULE__{to: to, content: content}) do
         # Invoke some API to send SMS..
         # SMSClient.send(to, content)
         {:ok, nil}
       end
     end

  And then, assuming your only going to push tasks,
  you can configure your queue and workers like so:

     {:ok, queue} = Qui.JobQueue.start_link()
     {:ok, worker} = Worker.start_link(queue, &Qui.Task.process/1)
     Qui.JobQueue.enqueue(queue, %Tasks.SendSMS{to: "012345678", content: "Your OTP code is 1234"})
  """
  alias Qui.Job

  # Anything that implements the `Qui.Task` behaviour
  # (not sure how to type hint that)
  @type t() :: term()
  @callback perform(Job.t()) :: :ok | {:error, Exception.t()}

  @doc """
  Default processor function for tasks that implement the `Qui.Task` behaviour,
  which simply dispatches to the `perform/1` function of the callback module.
  """
  @spec process(Job.t()) :: {:ok, term()} | {:error, Exception.t()}
  def process(%Job{task: %module{}} = job) do
    apply(module, :perform, [job])
  end
end
