# frozen_string_literal: true

require "test_helper"

# The named-pipe IO (Windows' local API) honours the read timeouts Net::BufferedIO
# asks for, though a pipe's reads block: an OS pipe stands in for the named pipe.
class PipeIOTest < Minitest::Test
  def test_reads_wait_with_a_timeout_and_end_at_eof
    r, w = IO.pipe
    io = GaiaDesk::HTTP::PipeIO.new(r)

    assert_equal :wait_readable, io.read_nonblock(16, exception: false)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_nil io.wait_readable(0.3), "nothing arrived"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :>=, 0.25

    w.write("hello world")

    assert io.wait_readable(5)
    buf = +""

    assert_equal "hello", io.read_nonblock(5, buf, exception: false)
    assert_equal "hello", buf
    assert_equal " world", io.read_nonblock(16, exception: false)
    w.close

    assert io.wait_readable(5)
    assert_nil io.read_nonblock(16, exception: false)
    assert_predicate io, :eof?
  ensure
    w.close unless w.closed?
    r.close unless r.closed?
  end

  def test_close_does_not_wait_for_a_blocked_read
    r, w = IO.pipe
    io = GaiaDesk::HTTP::PipeIO.new(r)

    assert_nil io.wait_readable(0.05)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    io.close

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, 1
  ensure
    w&.close
  end
end
