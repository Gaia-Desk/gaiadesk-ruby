# frozen_string_literal: true

require "net/http"
require "openssl"
require "socket"
require "uri"

module GaiaDesk
  # The HTTP layer under every transport: Net::HTTP, one connection per request,
  # opened over TCP (+api+), TLS with a pinned certificate (+lan+), a Unix socket
  # or a Windows named pipe (+local+). Every wait on the network is bounded by the
  # client's +response_timeout+ (the answer beginning) and +idle_timeout+ (each read
  # of its body).
  module HTTP
    # The exceptions that mean a request got no (complete) answer.
    NETWORK_ERRORS = [
      SocketError, IOError, EOFError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::ProtocolError
    ].freeze

    # Raised (and mapped by the transport) when nothing could be connected: the
    # request was never sent, so it is always safe to send again.
    class ConnectFailed < StandardError
      # @return [Exception] what the connect raised
      attr_reader :cause_error

      def initialize(error)
        super(error.message)
        @cause_error = error
      end
    end

    # Net::BufferedIO's per-read and per-write timeouts, also held to a deadline while
    # it is set: no single wait outlasts it, so the wait for an answer to begin (sending
    # the request included) is bounded as a whole, not per read.
    module Deadline
      # @return [Float, nil] a monotonic clock time, or +nil+ for none
      attr_accessor :gaiadesk_deadline

      private

      def rbuf_fill
        @read_timeout = gaiadesk_left(@read_timeout)
        super
      end

      def write0(*strs)
        @write_timeout = gaiadesk_left(@write_timeout)
        super
      end

      def gaiadesk_left(timeout)
        return timeout if @gaiadesk_deadline.nil?

        [@gaiadesk_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.0].max
      end
    end

    # Net::HTTP for one request: no silent re-sends (Net::HTTP sends a GET, HEAD, PUT,
    # DELETE, OPTIONS or TRACE again by itself after most network errors, +max_retries+
    # 1; a PUT's streamed body cannot be sent twice), and a {#deadline=} for the wait
    # for its answer to begin.
    class Connection < Net::HTTP
      def initialize(*)
        super
        self.max_retries = 0
      end

      # The deadline (a monotonic clock time, or +nil+) for every read and write until it
      # is set back to +nil+.
      def deadline=(time)
        @socket.gaiadesk_deadline = time if @socket.respond_to?(:gaiadesk_deadline=)
      end

      private

      def connect
        super
        @socket.extend(Deadline)
      end
    end

    # Net::HTTP over a socket the caller opens (a Unix socket, a named pipe):
    # +connector+ returns the IO; the Host header is +localhost+.
    class SocketHTTP < Connection
      # A Net::HTTP whose connections +connector+ opens.
      def self.over(connector)
        http = new("localhost", 80)
        http.connector = connector
        http
      end

      # @return [#call] returns the connected IO
      attr_accessor :connector

      private

      def connect
        io = @connector.call
        @socket = Net::BufferedIO.new(io, read_timeout: @read_timeout, write_timeout: @write_timeout,
                                          continue_timeout: @continue_timeout, debug_output: @debug_output)
        @socket.extend(Deadline)
        on_connect
      end
    end

    # A Windows named pipe (a File) with the IO methods Net::BufferedIO uses. A pipe
    # has no non-blocking reads here, so once the request is written (a synchronous
    # pipe serializes a read and a write on one handle) a thread reads it, and
    # {#wait_readable} waits for that thread with a timeout: the read and idle timeouts
    # hold on a pipe too. A closed pipe is the end of the answer.
    class PipeIO
      def initialize(file)
        @f = file
        @lock = Mutex.new
        @ready = ConditionVariable.new
        @chunks = []
        @eof = false
        @reader = nil
      end

      def read_nonblock(len, buf = nil, exception: true) # rubocop:disable Lint/UnusedMethodArgument
        @lock.synchronize do
          start_reader
          if @chunks.empty?
            return nil if @eof

            return :wait_readable
          end
          data = take(len)
          buf ? buf.replace(data) : data
        end
      end

      def write_nonblock(str, exception: true) # rubocop:disable Lint/UnusedMethodArgument
        @f.write(str)
      end

      def write(*strs)
        @f.write(*strs)
      end

      def to_io
        self
      end

      # Whether something (or the end) arrived within +timeout+ seconds (+nil+: no limit).
      def wait_readable(timeout = nil)
        deadline = timeout && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout)
        @lock.synchronize do
          start_reader
          while @chunks.empty? && !@eof
            left = deadline && (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
            return nil if left && left <= 0

            @ready.wait(@lock, left)
          end
          self
        end
      end

      def wait_writable(_timeout = nil)
        self
      end

      def eof?
        @lock.synchronize { @chunks.empty? && @eof }
      end

      def closed?
        @f.closed?
      end

      # Closes the pipe; while the reading thread is still blocked on it, from another
      # thread, so that closing never waits on a read that may never end.
      def close
        reader = @lock.synchronize { @reader }
        if reader&.alive?
          Thread.new { close_file }.report_on_exception = false
        else
          close_file
        end
      end

      private

      def close_file
        @f.close unless @f.closed?
      rescue IOError, SystemCallError
        nil
      end

      def start_reader
        return if @reader

        @reader = Thread.new { pump }
        @reader.report_on_exception = false
      end

      def pump
        loop do
          data = @f.readpartial(65_536)
          @lock.synchronize do
            @chunks << data
            @ready.broadcast
          end
        end
      rescue IOError, SystemCallError # EOFError is an IOError
        @lock.synchronize do
          @eof = true
          @ready.broadcast
        end
      end

      def take(len)
        head = @chunks.first
        return @chunks.shift if head.bytesize <= len

        @chunks[0] = head.byteslice(len, head.bytesize - len)
        head.byteslice(0, len)
      end
    end

    module_function

    # A SHA-256 certificate fingerprint as a desk's Settings shows it: 32 lowercase
    # hex pairs joined by +:+. Takes it with or without colons (or spaces), any case.
    # @raise [UsageError] when it is not one
    def normalize_fingerprint(fingerprint)
      h = fingerprint.is_a?(String) ? fingerprint.gsub(/[\s:]/, "").downcase : ""
      unless h.match?(/\A[0-9a-f]{64}\z/)
        raise UsageError.new("fingerprint must be the gateway certificate's SHA-256 fingerprint: 32 hex pairs " \
                             "(ab:cd:…, as the desk's Settings shows it), got #{fingerprint.inspect}", kind: "usage")
      end

      h.scan(/../).join(":")
    end

    # The SHA-256 fingerprint of a certificate (DER bytes or an OpenSSL::X509::Certificate).
    def certificate_fingerprint(cert)
      der = cert.respond_to?(:to_der) ? cert.to_der : cert
      normalize_fingerprint(OpenSSL::Digest::SHA256.hexdigest(der))
    end
  end
end
