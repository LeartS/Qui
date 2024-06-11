defmodule Qui.Job do
  @moduledoc """
  A job represents a specific instance of some work to be executed.

  The work is defined by the `:task` field which, in order to keep the JobQueue generic,
  can be any term; but you might want to use a module implementing the `Qui.Task` behaviour.

  The other fields are job-specific and defined when a job is created by pushing
  to the `Qui.JobQueue`.
  """
  alias Qui.JobQueue

  # Jobs should be instantiated by `Qui.JobQueue.enqueue/1`, not directly
  # The job defaults are embedded in the `Qui.JobQueue` module so that
  # in a future evolution we can allow users to specify queue-specific defaults.
  # Therefore, we mark all fields as enforced and don't set any defaults here
  # to avoid having multiple sources of (potentially different) defaults.
  @enforce_keys [
    :id,
    :task,
    :priority,
    :max_retries,
    :retry_delay,
    :timeout,
    :attempts,
    :enqueued_at
  ]
  defstruct id: nil,
            task: nil,
            priority: nil,
            max_retries: nil,
            retry_delay: nil,
            timeout: nil,
            # job state
            attempts: nil,
            enqueued_at: nil

  @type t() :: %__MODULE__{
          id: String.t(),
          task: term(),
          priority: JobQueue.priority(),
          max_retries: non_neg_integer(),
          retry_delay: non_neg_integer(),
          timeout: non_neg_integer() | :infinity,
          attempts: non_neg_integer(),
          enqueued_at: DateTime.t()
        }
end
