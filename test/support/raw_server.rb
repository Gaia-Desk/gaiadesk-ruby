# frozen_string_literal: true

require "json"
require "socket"

# A TCP server with no HTTP framework, for the failures a real one never produces on
# purpose: a connection closed or reset before any answer byte (with or without the
# request's body read), an answer that stalls mid-body / mid-JSON / mid-event-stream
# with the socket left open, and a server that never answers at all. It counts the
# requests per method; the mode can change while it runs; held sockets are closed by
# #close.
class RawServer
  MODES = %i[close_before_response reset_before_response close_after_body stall_mid_body stall_mid_json
             stall_mid_events silent trickle_head status ok keep_alive_then_close].freeze
  # What +ok+ and +keep_alive_then_close+ answer: JSON every operation reads as a result.
  OK_BODY = '{"exit":0,"stdout":"","stderr":"","failed":[]}'

  attr_accessor :mode
  # +status+ mode's answer: <tt>[code, retry_after or nil, reason or nil]</tt>.
  attr_accessor :status

  # +server+: another listening socket (a UNIXServer) instead of TCP on 127.0.0.1.
  def initialize(mode, server: nil)
    @mode = mode
    @server = server || TCPServer.new("127.0.0.1", 0)
    @lock = Mutex.new
    @counts = Hash.new(0)
    @held = []
    @workers = []
    @thread = Thread.new { accept_loop }
    @thread.report_on_exception = false
  end

  def port
    @server.addr[1]
  end

  def url
    "http://127.0.0.1:#{port}/v1"
  end

  # How many requests of +method+ arrived.
  def count(method)
    @lock.synchronize { @counts[method] }
  end

  def reset_counts
    @lock.synchronize { @counts.clear }
  end

  def close
    @server.close
  rescue IOError
    nil
  ensure
    @thread.kill
    @lock.synchronize do
      @held.each { |s| s.close unless s.closed? }
      @held.clear
      @workers.each(&:kill)
    end
  end

  private

  def accept_loop
    loop do
      sock = @server.accept
      t = Thread.new(sock) { |s| serve(s) }
      t.report_on_exception = false
      @lock.synchronize { @workers << t }
    end
  rescue IOError, SystemCallError
    nil
  end

  def serve(sock)
    head = read_head(sock)
    return sock.close if head.nil?

    method = head[/\A\S+/]
    @lock.synchronize { @counts[method] += 1 }
    case @mode
    when :status
      read_body(sock, head)
      answer_status(sock)
    when :ok
      read_body(sock, head)
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{OK_BODY.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{OK_BODY}")
      sock.close
    when :keep_alive_then_close # the first request answered with keep-alive; the next one on it dropped
      read_body(sock, head)
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{OK_BODY.bytesize}\r\n" \
                 "Connection: keep-alive\r\n\r\n#{OK_BODY}")
      head = read_head(sock)
      if head
        method = head[/\A\S+/]
        @lock.synchronize { @counts[method] += 1 }
      end
      sock.close
    when :close_before_response then sock.close
    when :reset_before_response then reset(sock)
    when :close_after_body
      read_body(sock, head)
      sock.close
    when :stall_mid_body
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n")
      hold(sock)
    when :stall_mid_json
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{\"desk\":")
      hold(sock)
    when :stall_mid_events
      ev = "event: stdout\ndata: {\"event\":\"stdout\",\"data\":\"hi\"}\n\n"
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n" \
                 "#{ev.bytesize.to_s(16)}\r\n#{ev}\r\n")
      hold(sock)
    when :trickle_head # a status line, then a header a byte every 0.2 s that never ends
      hold(sock)
      sock.write("HTTP/1.1 200 OK\r\nX-Slow: ")
      loop do
        sock.write("x")
        sleep 0.2
      end
    else hold(sock) # :silent
    end
  rescue IOError, SystemCallError
    sock.close unless sock.closed?
  end

  def answer_status(sock)
    code, retry_after, reason = @status
    kind = { 429 => "refused", 409 => "unreachable", 502 => "connection_lost" }.fetch(code, "unreachable")
    err = { "kind" => kind, "message" => "status #{code}" }
    err["reason"] = reason if reason
    body = JSON.generate({ "error" => err })
    head = "HTTP/1.1 #{code} Status\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n"
    head << "Retry-After: #{retry_after}\r\n" if retry_after
    sock.write("#{head}\r\n#{body}")
    sock.close
  end

  def hold(sock)
    @lock.synchronize { @held << sock }
  end

  # An RST, not a FIN: SO_LINGER on with a zero timeout, then close.
  def reset(sock)
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
    sock.close
  end

  def read_head(sock)
    head = +"".b
    until head.end_with?("\r\n\r\n")
      c = sock.read(1)
      return nil if c.nil?

      head << c
    end
    head
  end

  def read_body(sock, head)
    if head =~ /^content-length:\s*(\d+)/i
      left = Regexp.last_match(1).to_i
      while left.positive?
        b = sock.readpartial([left, 65_536].min)
        left -= b.bytesize
      end
    elsif head =~ /^transfer-encoding:\s*chunked/i
      loop do
        size = sock.gets("\r\n").to_s.strip.to_i(16)
        sock.read(size + 2)
        break if size.zero?
      end
    end
  rescue EOFError
    nil
  end
end
