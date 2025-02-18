require_relative "helper"

class TestBusyWorker < Minitest::Test
  def setup
    skip_unless :mri # This feature only makes sense on MRI
    @ios = []
    @server = nil
  end

  def teardown
    return if skipped?
    @server.stop(true) if @server
    @ios.each {|i| i.close unless i.closed?}
  end

  def new_connection
    TCPSocket.new('127.0.0.1', @port).tap {|s| @ios << s}
  rescue IOError
    Puma::Util.purge_interrupt_queue
    retry
  end

  def send_http(req)
    new_connection << req
  end

  def send_http_and_read(req)
    send_http(req).read
  end

  def with_server(**options, &app)
    @requests_count = 0 # number of requests processed
    @requests_running = 0 # current number of requests running
    @requests_max_running = 0 # max number of requests running in parallel
    @mutex = Mutex.new

    request_handler = ->(env) do
      @mutex.synchronize do
        @requests_count += 1
        @requests_running += 1
        if @requests_running > @requests_max_running
          @requests_max_running = @requests_running
        end
      end

      begin
        yield(env)
      ensure
        @mutex.synchronize do
          @requests_running -= 1
        end
      end
    end

    options[:min_threads] ||= 0
    options[:max_threads] ||= 10
    options[:log_writer]  ||= Puma::LogWriter.strings

    @server = Puma::Server.new request_handler, nil, **options
    @port = (@server.add_tcp_listener '127.0.0.1', 0).addr[1]
    @server.run
  end

  # Multiple concurrent requests are not processed
  # sequentially as a small delay is introduced
  def test_multiple_requests_waiting_on_less_busy_worker
    with_server(wait_for_less_busy_worker: 1.0) do |_|
      sleep(0.1)

      [200, {}, [""]]
    end

    n = 2

    Array.new(n) do
      Thread.new { send_http_and_read "GET / HTTP/1.0\r\n\r\n" }
    end.each(&:join)

    assert_equal n, @requests_count, "number of requests needs to match"
    assert_equal 0, @requests_running, "none of requests needs to be running"
    assert_equal 1, @requests_max_running, "maximum number of concurrent requests needs to be 1"
  end

  # Multiple concurrent requests are processed
  # in parallel as a delay is disabled
  def test_multiple_requests_processing_in_parallel
    with_server(wait_for_less_busy_worker: 0.0) do |_|
      sleep(0.1)

      [200, {}, [""]]
    end

    n = 4

    Array.new(n) do
      Thread.new { send_http_and_read "GET / HTTP/1.0\r\n\r\n" }
    end.each(&:join)

    assert_equal n, @requests_count, "number of requests needs to match"
    assert_equal 0, @requests_running, "none of requests needs to be running"
    assert_equal n, @requests_max_running, "maximum number of concurrent requests needs to match"
  end
end
