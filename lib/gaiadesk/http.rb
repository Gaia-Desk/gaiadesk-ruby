# frozen_string_literal: true

require "net/http"
require "openssl"
require "socket"
require "uri"

module GaiaDesk
  # The HTTP layer under every transport: Net::HTTP, one connection per request,
  # opened over TCP (+api+), TLS with a pinned certificate (+lan+), a Unix socket
  # or a Windows named pipe (+local+).
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

    # Net::HTTP over a socket the caller opens (a Unix socket, a named pipe):
    # +connector+ returns the IO; the Host header is +localhost+.
    class SocketHTTP < Net::HTTP
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
        on_connect
      end
    end

    # A Windows named pipe (a File) with the IO methods Net::BufferedIO uses.
    # Reads block (pipes have no non-blocking reads here); a closed pipe is the
    # end of the answer.
    class PipeIO
      def initialize(file)
        @f = file
      end

      def read_nonblock(len, buf = nil, exception: true) # rubocop:disable Lint/UnusedMethodArgument
        @f.readpartial(len, buf)
      rescue EOFError, Errno::EPIPE
        nil
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

      def wait_readable(_timeout = nil)
        true
      end

      def wait_writable(_timeout = nil)
        true
      end

      def eof?
        @f.eof?
      end

      def closed?
        @f.closed?
      end

      def close
        @f.close unless @f.closed?
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
