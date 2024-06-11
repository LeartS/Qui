defmodule Qui.WorkerTest do
  use ExUnit.Case

  alias Qui.Job
  alias Qui.Tasks
  alias Qui.JobQueue
  alias Qui.Worker

  @spec mailbox_empty?(non_neg_integer()) :: boolean()
  defp mailbox_empty?(timeout \\ 10) do
    receive do
      _any -> false
    after
      timeout -> true
    end
  end

  test "workers process jobs sequentially" do
    test_pid = self()
    {:ok, q} = JobQueue.start_link()

    # a processor function which
    # - sends a message to the test process when a job is processed
    # - blocks until it receives a :continue_processing message
    processor = fn job ->
      send(test_pid, {:processed, job, self()})

      receive do
        :continue_processing -> nil
      end

      {:ok, nil}
    end

    {:ok, _worker_pid} = Worker.start_link({q, processor})
    %Job{} = job_one = JobQueue.enqueue(q, :task_one)
    %Job{} = job_two = JobQueue.enqueue(q, :task_two)
    assert_receive {:processed, ^job_one, processor_pid}, 10
    # assert that the second job has not been processed
    # yet, because the processor is waiting on a :continue message
    assert mailbox_empty?()
    # unblock the processor
    send(processor_pid, :continue_processing)
    # assert the next job is processed
    assert_receive {:processed, ^job_two, _pid}, 10
  end

  test "concurrent worker processing" do
    task = %Tasks.SendEmail{
      to: "test@v7.com",
      body: "Hello, world!",
      subject: "Test email"
    }

    test_pid = self()

    # Processor function which reports to the test process whenever a job is processed,
    # sending the pid of the worker who processed the job; and then hangs indefinitely
    make_processor = fn reference ->
      fn _job ->
        send(test_pid, {:processed, reference})
        Process.sleep(:infinity)
        {:ok, nil}
      end
    end

    {:ok, q} = JobQueue.start_link()
    {:ok, _w1_pid} = Worker.start_link({q, make_processor.(:worker_one)})
    {:ok, _w2_pid} = Worker.start_link({q, make_processor.(:worker_two)})
    assert %Job{} = JobQueue.enqueue(q, task)
    assert %Job{} = JobQueue.enqueue(q, task)

    assert_receive {:processed, :worker_one}, 10
    assert_receive {:processed, :worker_two}, 10
  end

  test "jobs are retried on failure, and their attempts count is incremented" do
    test_pid = self()
    {:ok, q} = JobQueue.start_link()

    %Job{} = JobQueue.enqueue(q, :task_a, max_retries: 1, retry_delay: 0)

    processor = fn job ->
      send(test_pid, {:processing_attempt, job})
      {:error, %RuntimeError{message: "test failure"}}
    end

    {:ok, _worker_pid} = Worker.start_link({q, processor})
    assert_receive {:processing_attempt, %Job{attempts: 0}}, 10
    assert_receive {:processing_attempt, %Job{attempts: 1}}, 10
  end

  test "retry delay can be specified per job" do
    test_pid = self()
    {:ok, q} = JobQueue.start_link()

    %Job{} = JobQueue.enqueue(q, :task_a, max_retries: 1, retry_delay: 30)

    processor = fn job ->
      send(test_pid, {:processing_attempt, job, DateTime.utc_now(:millisecond)})
      {:error, %RuntimeError{message: "test failure"}}
    end

    {:ok, _worker_pid} = Worker.start_link({q, processor})

    assert_receive {:processing_attempt, %Job{attempts: 0}, first_attempt_dt}, 10
    assert_receive {:processing_attempt, %Job{attempts: 1}, second_attempt_dt}, 50
    assert DateTime.diff(second_attempt_dt, first_attempt_dt, :millisecond) > 28
  end

  test "number of retries can be specified per job" do
    test_pid = self()
    {:ok, q} = JobQueue.start_link()

    %Job{} = JobQueue.enqueue(q, :task_a, max_retries: 5, retry_delay: 0)

    processor = fn job ->
      send(test_pid, {:processing_attempt, job})
      {:error, %RuntimeError{message: "test failure"}}
    end

    {:ok, _worker_pid} = Worker.start_link({q, processor})

    assert_receive {:processing_attempt, %Job{attempts: 0}}, 5
    assert_receive {:processing_attempt, %Job{attempts: 1}}, 5
    assert_receive {:processing_attempt, %Job{attempts: 2}}, 5
    assert_receive {:processing_attempt, %Job{attempts: 3}}, 5
    assert_receive {:processing_attempt, %Job{attempts: 4}}, 5
    assert_receive {:processing_attempt, %Job{attempts: 5}}, 5
    assert mailbox_empty?()
  end

  test "if processor raises, job is retried" do
    test_pid = self()
    {:ok, q} = JobQueue.start_link()

    %Job{} = JobQueue.enqueue(q, :task_a, max_retries: 1, retry_delay: 0)

    processor = fn job ->
      send(test_pid, {:processing_attempt, job})
      raise "oops"
    end

    {:ok, _worker_pid} = Worker.start_link({q, processor})

    assert_receive {:processing_attempt, %Job{attempts: 0}}, 10
    assert_receive {:processing_attempt, %Job{attempts: 1}}, 10
  end

  test "job processing is killed after timeout, and job is retried" do
    test_pid = self()
    {:ok, q} = JobQueue.start_link()

    # This processor will never complete
    # We rely on the Worker module to kill it when it times out,
    # to free the worker so that it can pick up new jobs and retries.
    processor = fn job ->
      send(test_pid, {:processing, job, self()})
      Process.sleep(:infinity)
    end

    {:ok, worker_pid} = Worker.start_link({q, processor})
    %Job{} = JobQueue.enqueue(q, :task_a, retry_delay: 0, timeout: 10)

    assert_receive {:processing, %Job{attempts: 0}, processor1_pid}, 50
    assert_receive {:processing, %Job{attempts: 1}, processor2_pid}, 50
    # Check that the timeout did not kill the worker process
    assert Process.alive?(worker_pid)
    assert processor1_pid != processor2_pid
  end
end
