# Qui

A distributed queue and asynchronous task processing system for Elixir applications.

## Status

Qui is currently under development and is currently in alpha status.
It should not be considered a working library yet;
the recommended "usage" as of now is to peruse the code and copy any parts that may seem useful / take inspiration.

## Architecture

* **Each worker instance processes jobs sequentially.**
  Therefore, the maximum concurrency is dictated by the number of available workers,
  and it is easy to see and reason about the runtime characteristics of the system by looking at the workers supervision tree.
* **Workers interact with the queue by polling it**.
  As soon as a worker is finished processing a job, they will poll the queue they're connected to to request a new one.
  This means there could be a few milliseconds processing delay when a a job is added to the queue, even if all the workers are free.
* **Each queue supports :high and :low priority jobs**
  High priority jobs are always processed before low priority ones,
  even if the low priority ones are much older.  
  This might result in low priority jobs being processed extremely late, or even not at all,
  if high priority jobs are enqueued at the same rate they are processed.  
  Future evolutions might support smarter scheduling systems,
  but in the meantime it's possible to work around the problem by using multiple queues
  (see next point). 
* **Each worker connects to a specific queue, and it is possible to have multiple queues**
  By simply changing the supervision tree in `Qui.Application`, it is possible to
  start multiple JobQueues, each one with its own set of specialized workers.

  For example, you might have:
  * A JobQueue for CPU-bound work with a few workers (~ number of machine cores) and a JobQueue for IO-bound ones with hundreds of workers
  * A JobQueue per task type, to have different concurrency per task type.
  * A JobQueue for task types which have no processing implementation yet.  
  (this queue will grow indefinitely, not recommended unless you expect to add some workers for it before it gets too large)
  * A more granular/fair/flexible scheduling system than the one provided by a single JobQueue,
  by having different queues per priority, with different number of workers based on priority. e.g. different queues for customer tiers like Ultimate, Enterprise, Pro, Standard; with more workers allocated to higher tiers.
  * Any combination of the above

* **At-most-once delivery semantics**  
  A job is removed from the queue as soon as it is sent to a worker process,
  without waiting for confirmation of its handling.  
  In case of worker crashes, the job might be lost.
* **The JobQueue is self-contained and independent of workers.**
  The poll-based architecture allows the queue to be self-contained and independent of workers. The `JobQueue` can be used even without workers, by using its APIs directly.
* **Workers delegate the job processing logic to user-supplied processor functions**
  The `Qui.Worker` module is responsible for interacting with the queue in a sensible way, handling errors and retries, etc.  
  The actual job processing logic must be supplied to the worker by providing it with a processor function, which must have the signature
  ```elixir
  @type processor_function() :: (Qui.Job.t() -> {:ok, term()} | {:error, Exception.t()})
  ```
  i.e. it takes a `Qui.Job` and must return either `{:ok, <return_value>}` or `{:error, <error struct>}`. The return value is currently ignored.

  The `{:error, Exception.t()}` type is a way to return structured error values which are detailed but easy to work it. See these two blogposts for the reasoning behind it:
  * [Leveraging Exceptions to Handle Errors in Elixir](https://leandrocp.com.br/2020/08/leveraging-exceptions-to-handle-errors-in-elixir/)
  * [Elixir Best Practices for Error Values](https://medium.com/@moxicon/elixir-best-practices-for-error-values-50dc015a06f5)

  So it is up to the processor function to catch exceptions and returns them as an `{:error, <error>}` value instead.  
  As a fallback, the `Qui.Worker` module will catch any uncaught exceptions and handle them as if they were returned explicitly.  
  If, instead, the processor function returns a non-confirming value, the worker process will crash in a "let it crash" and "fail fast" approach,
  so that the implementor can fix their processor functions.
* **Support for job processing timeout**
  To avoid job processing getting stuck and blocking a worker,
  it is possible to set a processing timeout when adding jobs to the queue.  
  If the job processing takes longer, it is automatically killed by the worker and handled as an error.
  (i.e. the job will be retried according to the retry params).
* **Task behaviour**
  The job queue supports any elixir term as a task, but the system provides the `Qui.Task` behaviour for structure and convenience.  
  If all the tasks pushed to a queue are callbacks of `Qui.Task`,
  you can simply pass `Qui.Task.process/1` as the processor function of a worker, which will automatically dispatch to the specific task's `perform/1` function.  
  This allows for colocation of a task definition/struct/params and handling logic.


## TODO
* Code quality tooling: credo, dialyxir, etc. etc.
* Some parts are partially generalized.
  For example, the two priority levels `:high` and `:low` are currently hardcoded,
  but the code already has some flexible logic so that it should be easy to add more priorities in future evolutions.
* It should be quite easy to make the job processing system partially distributed by using OTP distribution and using a `{:global, <name>}` name for the queues,
  so that they are reachable by any connected node.
  Each queue would live on one node only, but workers can be distributed across nodes,
  and each node could be responsible for a subset of queues.  
  I have not tested this (or wrote tests for it) but it should work (or almost) already
* Persistence is very basic and with no reliability guarantees or tuning.