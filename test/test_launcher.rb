require_relative "helper"
require_relative "helpers/tmp_path"

require "puma/configuration"
require 'puma/log_writer'

class TestLauncher < Minitest::Test
  include TmpPath

  def test_prints_thread_traces
    launcher.thread_status do |name, _backtrace|
      assert_match "Thread: TID", name
    end
  end

  def test_pid_file
    pid_path = tmp_path('.pid')

    conf = Puma::Configuration.new do |c|
      c.pidfile pid_path
    end

    launcher(conf).write_state

    assert_equal File.read(pid_path).strip.to_i, Process.pid

    File.unlink pid_path
  end

  def test_state_permission_0640
    state_path = tmp_path('.state')
    state_permission = 0640

    conf = Puma::Configuration.new do |c|
      c.state_path state_path
      c.state_permission state_permission
    end

    launcher(conf).write_state

    assert File.stat(state_path).mode.to_s(8)[-4..-1], state_permission
  ensure
    File.unlink state_path
  end

  def test_state_permission_nil
    state_path = tmp_path('.state')

    conf = Puma::Configuration.new do |c|
      c.state_path state_path
      c.state_permission nil
    end

    launcher(conf).write_state

    assert File.exist?(state_path)
  ensure
    File.unlink state_path
  end

  def test_no_state_permission
    state_path = tmp_path('.state')

    conf = Puma::Configuration.new do |c|
      c.state_path state_path
    end

    launcher(conf).write_state

    assert File.exist?(state_path)
  ensure
    File.unlink state_path
  end

  def test_puma_stats
    conf = Puma::Configuration.new do |c|
      c.app -> {[200, {}, ['']]}
      c.clear_binds!
    end
    launcher = launcher(conf)
    launcher.events.on_booted {
      sleep 1.1 unless Puma.mri?
      launcher.stop
    }
    launcher.run
    sleep 1 unless Puma.mri?
    Puma::Server::STAT_METHODS.each do |stat|
      assert_includes Puma.stats_hash, stat
    end
  end

  def test_puma_stats_clustered
    skip_unless :fork

    conf = Puma::Configuration.new do |c|
      c.app -> {[200, {}, ['']]}
      c.workers 1
      c.clear_binds!
    end
    launcher = launcher(conf)
    Thread.new do
      sleep Puma::Configuration::DEFAULTS[:worker_check_interval] + 1
      status = Puma.stats_hash[:worker_status].first[:last_status]
      Puma::Server::STAT_METHODS.each do |stat|
        assert_includes status, stat
      end
      launcher.stop
    end
    launcher.run
  end

  def test_log_config_enabled
    ENV['PUMA_LOG_CONFIG'] = "1"

    assert_match(/Configuration:/, launcher.log_writer.stdout.string)

    launcher.config.final_options.each do |config_key, _value|
      assert_match(/#{config_key}/, launcher.log_writer.stdout.string)
    end

    ENV.delete('PUMA_LOG_CONFIG')
  end

  def test_log_config_disabled
    refute_match(/Configuration:/, launcher.log_writer.stdout.string)
  end

  def test_fire_on_stopped
    conf = Puma::Configuration.new do |c|
      c.app -> {[200, {}, ['']]}
      c.port UniquePort.call
    end

    launcher = launcher(conf)
    launcher.events.on_booted {
      sleep 1.1 unless Puma.mri?
      launcher.stop
    }
    launcher.events.on_stopped { puts 'on_stopped called' }

    out, = capture_io do
      launcher.run
    end
    sleep 0.2 unless Puma.mri?
    assert_equal 'on_stopped called', out.strip
  end

  private

  def log_writer
    @log_writer ||= Puma::LogWriter.strings
  end

  def launcher(config = Puma::Configuration.new, lw = log_writer)
    @launcher ||= Puma::Launcher.new(config, log_writer: lw)
  end
end
