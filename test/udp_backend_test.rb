# frozen_string_literal: true

require 'test_helper'

class UDPBackendTest < Minitest::Test
  def setup
    StatsD.legacy_singleton_client.stubs(:backend).returns(@backend = StatsD::Instrument::Backends::UDPBackend.new)
    @backend.stubs(:rand).returns(0.0)

    UDPSocket.stubs(:new).returns(@socket = mock('socket'))
    @socket.stubs(:connect)
    @socket.stubs(:send).returns(1)

    StatsD.stubs(:logger).returns(@logger = mock('logger'))
  end

  def test_changing_host_or_port_should_create_new_socket
    @socket.expects(:connect).with('localhost', 1234).once
    @socket.expects(:connect).with('localhost', 2345).once
    @socket.expects(:connect).with('127.0.0.1', 2345).once

    @backend.server = "localhost:1234"
    @backend.socket

    @backend.port = 2345
    @backend.socket

    @backend.host = '127.0.0.1'
    @backend.socket
  end

  def test_collect_respects_sampling_rate
    @socket.expects(:send).once.returns(1)
    metric = StatsD::Instrument::Metric.new(type: :c, name: 'test', sample_rate: 0.5)

    @backend.stubs(:rand).returns(0.4)
    @backend.collect_metric(metric)

    @backend.stubs(:rand).returns(0.6)
    @backend.collect_metric(metric)
  end

  def test_support_counter_syntax
    @backend.expects(:write_packet).with('counter:1|c').once
    StatsD.increment('counter', sample_rate: 1.0)

    @backend.expects(:write_packet).with('counter:1|c|@0.5').once
    StatsD.increment('counter', sample_rate: 0.5)
  end

  def test_supports_gauge_syntax
    @backend.expects(:write_packet).with('fooy:1.23|g')
    StatsD.gauge('fooy', 1.23)

    @backend.expects(:write_packet).with('fooy:42|g|@0.01')
    StatsD.gauge('fooy', 42, sample_rate: 0.01)
  end

  def test_supports_set_syntax
    @backend.expects(:write_packet).with('unique:10.0.0.10|s')
    StatsD.set('unique', '10.0.0.10')

    @backend.expects(:write_packet).with('unique:10.0.0.10|s|@0.01')
    StatsD.set('unique', '10.0.0.10', sample_rate: 0.01)
  end

  def test_support_measure_syntax
    @backend.expects(:write_packet).with('duration:1.23|ms')
    StatsD.measure('duration', 1.23)

    @backend.expects(:write_packet).with('duration:0.42|ms|@0.01')
    StatsD.measure('duration', 0.42, sample_rate: 0.01)
  end

  def test_histogram_syntax_on_datadog
    @backend.implementation = :datadog
    @backend.expects(:write_packet).with('fooh:42.4|h')
    StatsD.histogram('fooh', 42.4)
  end

  def test_distribution_syntax_on_datadog
    @backend.implementation = :datadog
    @backend.expects(:write_packet).with('fooh:42.4|d')
    StatsD.distribution('fooh', 42.4)
  end

  def test_event_on_datadog
    @backend.implementation = :datadog
    @backend.expects(:write_packet).with('_e{4,3}:fooh|baz|h:localhost|#foo')
    StatsD.event('fooh', 'baz', hostname: 'localhost', tags: ["foo"])
  end

  def test_event_on_datadog_escapes_newlines
    @backend.implementation = :datadog
    @backend.expects(:write_packet).with("_e{8,5}:fooh\\n\\n|baz\\n")
    StatsD.event("fooh\n\n", "baz\n")
  end

  def test_event_on_datadog_ignores_invalid_metadata
    @backend.implementation = :datadog
    if StatsD::Instrument.strict_mode_enabled?
      assert_raises(ArgumentError) { StatsD.event('fooh', 'baz', sample_rate: 0.01) }
      assert_raises(ArgumentError) { StatsD.event('fooh', 'baz', unsupported: 'foo') }
    else
      @backend.expects(:write_packet).with('_e{4,3}:fooh|baz')
      StatsD.event('fooh', 'baz', sample_rate: 0.01, i_am_not_supported: 'not-supported')
    end
  end

  def test_event_warns_when_not_using_datadog
    @backend.implementation = :other
    @backend.expects(:write_packet).never
    @logger.expects(:warn)
    StatsD.event('fooh', 'bar')
  end

  def test_service_check_on_datadog
    @backend.implementation = :datadog
    @backend.expects(:write_packet).with('_sc|fooh|0|h:localhost|#foo')
    StatsD.service_check('fooh', 0, hostname: 'localhost', tags: ["foo"])
  end

  def test_service_check_on_datadog_ignores_invalid_metadata
    @backend.implementation = :datadog
    if StatsD::Instrument.strict_mode_enabled?
      assert_raises(ArgumentError) { StatsD.service_check('fooh', "warning", sample_rate: 0.01) }
      assert_raises(ArgumentError) { StatsD.service_check('fooh', "warning", unsupported: 'foo') }
    else
      @backend.expects(:write_packet).with('_sc|fooh|1')
      StatsD.service_check('fooh', "warning", sample_rate: 0.01, i_am_not_supported: 'not-supported')
    end
  end

  def test_service_check_on_datadog_will_append_message_as_final_metadata_field
    @backend.implementation = :datadog
    @backend.expects(:write_packet).with('_sc|fooh|0|d:1230768000|#quc|m:Everything OK')
    StatsD.service_check('fooh', :ok, message: "Everything OK",
      timestamp: Time.parse('2009-01-01T00:00:00Z'), tags: ['quc'])
  end

  def test_service_check_warns_when_not_using_datadog
    @backend.implementation = :other
    @backend.expects(:write_packet).never
    @logger.expects(:warn)
    StatsD.service_check('fooh', 'bar')
  end

  def test_histogram_warns_if_not_using_datadog
    @backend.implementation = :other
    @backend.expects(:write_packet).never
    @logger.expects(:warn)
    StatsD.histogram('fooh', 42.4)
  end

  def test_distribution_warns_if_not_using_datadog
    @backend.implementation = :other
    @backend.expects(:write_packet).never
    @logger.expects(:warn)
    StatsD.distribution('fooh', 42.4)
  end

  def test_supports_key_value_syntax_on_statsite
    @backend.implementation = :statsite
    @backend.expects(:write_packet).with("fooy:42|kv\n")
    StatsD.key_value('fooy', 42)
  end

  # For key_value metrics (only supported by statsite), the sample rate
  # part of the datagram format is (ab)used to be set to a timestamp instead.
  # Changing that to `sample_rate: timestamp` does not make sense, so we
  # disable the rubocop rule for positional arguments for now,
  # until we figure out how we want to handle this.

  # rubocop:disable StatsD/PositionalArguments
  def test_supports_key_value_with_timestamp_on_statsite
    @backend.implementation = :statsite
    @backend.expects(:write_packet).with("fooy:42|kv|@123456\n")
    StatsD.key_value('fooy', 42, 123456)
  end
  # rubocop:enable StatsD/PositionalArguments

  def test_warn_when_using_key_value_and_not_on_statsite
    @backend.implementation = :other
    @backend.expects(:write_packet).never
    @logger.expects(:warn)
    StatsD.key_value('fookv', 3.33)
  end

  def test_support_tags_syntax_on_datadog
    @backend.implementation = :datadog
    @backend.expects(:write_packet).with("fooc:3|c|#topic:foo,bar")
    StatsD.increment('fooc', 3, tags: ['topic:foo', 'bar'])
  end

  def test_socket_error_should_not_raise_but_log
    @socket.stubs(:connect).raises(SocketError)
    @logger.expects(:error)
    StatsD.increment('fail')
  end

  def test_system_call_error_should_not_raise_but_log
    @socket.stubs(:send).raises(Errno::ETIMEDOUT)
    @logger.expects(:error)
    StatsD.increment('fail')
  end

  def test_io_error_should_not_raise_but_log
    @socket.stubs(:send).raises(IOError)
    @logger.expects(:error)
    StatsD.increment('fail')
  end

  def test_socket_error_should_invalidate_socket
    seq = sequence('fail_then_succeed')

    @socket.expects(:connect).with('localhost', 8125)
    @socket.expects(:send).raises(Errno::EDESTADDRREQ).in_sequence(seq)

    @socket.expects(:send).returns(1).in_sequence(seq)
    @logger.expects(:error)

    StatsD.increment('fail')
    StatsD.increment('succeed')
  end
end
