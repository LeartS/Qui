defmodule Qui.JobQueueTest do
  use ExUnit.Case

  alias Qui.Job
  alias Qui.JobQueue

  def send_arg_to_pid(pid) do
    fn arg -> send(pid, arg) end
  end

  test "enqueue/2 creates a job from the given task" do
    {:ok, q} = JobQueue.start_link()
    assert %Job{id: _id, task: _task} = JobQueue.enqueue(q, :task_one)
  end

  test "dequeue/1 returns :empty when no jobs (init)" do
    {:ok, q} = JobQueue.start_link()
    assert :empty = JobQueue.dequeue(q)
  end

  test "dequeue/1 returns :empty when no jobs (all jobs consumed)" do
    {:ok, q} = JobQueue.start_link()
    %Job{} = JobQueue.enqueue(q, :first_task)
    %Job{} = JobQueue.dequeue(q)
    assert :empty = JobQueue.dequeue(q)
  end

  test "dequeue/1 returns high priority jobs first" do
    {:ok, q} = JobQueue.start_link()
    job_one = JobQueue.enqueue(q, :low_priority_task, priority: :low)
    job_two = JobQueue.enqueue(q, :high_priority_task, priority: :high)
    assert ^job_two = JobQueue.dequeue(q)
    assert ^job_one = JobQueue.dequeue(q)
  end

  test "dequeue/1 returns jobs of the same priority in FIFO order" do
    {:ok, q} = JobQueue.start_link()
    job_one = JobQueue.enqueue(q, :task_one, priority: :low)
    job_two = JobQueue.enqueue(q, :task_two, prioirity: :low)
    assert ^job_one = JobQueue.dequeue(q)
    assert ^job_two = JobQueue.dequeue(q)
  end

  test "multiple queues are independent" do
    {:ok, qa} = JobQueue.start_link()
    {:ok, qb} = JobQueue.start_link()
    job_a = JobQueue.enqueue(qa, :task_a)
    job_b = JobQueue.enqueue(qb, :task_b)
    assert ^job_b = JobQueue.dequeue(qb)
    assert ^job_a = JobQueue.dequeue(qa)
  end

  test "queues can be registered and invoked with a name (local atom)" do
    {:ok, _queue_pid} = JobQueue.start_link(name: TestQueue)
    assert %Job{} = job = JobQueue.enqueue(TestQueue, :test_task)
    assert ^job = JobQueue.dequeue(TestQueue)
  end

  test "queues can be registered and invoked with a name (global)" do
    {:ok, _queue_pid} = JobQueue.start_link(name: {:global, GlobalTestQueue})
    assert %Job{} = job = JobQueue.enqueue({:global, GlobalTestQueue}, :test_task)
    assert ^job = JobQueue.dequeue({:global, GlobalTestQueue})
  end

  describe "persistence" do
    setup do
      filename = "/tmp/Qui_test_queue"
      on_exit(fn -> File.rm!(filename) end)
      %{queue_file: filename}
    end

    test "JobQueue initializes correctly with a new file", %{queue_file: queue_file} do
      {:ok, q} = JobQueue.start_link(persistence_filename: queue_file)
      assert :empty = JobQueue.dequeue(q)
    end

    test "jobs are restored from file", %{queue_file: queue_file} do
      {:ok, q} = JobQueue.start_link(persistence_filename: queue_file)
      job_one = JobQueue.enqueue(q, :job_one_task)
      job_two = JobQueue.enqueue(q, :job_two_task)

      # To prevent the test process from exiting when we stop the linked queue
      Process.flag(:trap_exit, true)
      Process.exit(q, :stop)
      assert not Process.alive?(q)
      Process.flag(:trap_exit, false)

      {:ok, q} = JobQueue.start_link(persistence_filename: queue_file)
      assert ^job_one = JobQueue.dequeue(q)
      assert ^job_two = JobQueue.dequeue(q)
    end
  end
end
