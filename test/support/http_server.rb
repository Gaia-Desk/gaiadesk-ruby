# frozen_string_literal: true

require "openssl"
require "socket"
require "uri"

# A small HTTP/1.1 server for the tests: one thread per connection, one request per
# connection (Connection: close), over TCP, TLS or a Unix socket. The handler gets a
# Request and a Response it writes to: whole JSON answers, streamed bodies written
# in pieces, or a connection cut mid-answer.
class TestHTTPServer
  Request = Struct.new(:method, :path, :query, :headers, :body) do
    def header(name)
      headers[name.downcase]
    end
  end

  # What a handler writes to.
  class Response
    REASONS = { 200 => "OK", 201 => "Created", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
                404 => "Not Found", 409 => "Conflict", 413 => "Payload Too Large", 422 => "Unprocessable Entity",
                429 => "Too Many Requests", 500 => "Internal Server Error", 502 => "Bad Gateway",
                503 => "Service Unavailable", 504 => "Gateway Timeout" }.freeze

    def initialize(io)
      @io = io
      @started = false
    end

    def started?
      @started
    end

    # Status line and headers; the body follows with #write until the connection closes.
    def start(status, headers = {})
      @started = true
      head = "HTTP/1.1 #{status} #{REASONS.fetch(status, 'Status')}\r\n"
      { "Connection" => "close" }.merge(headers).each { |k, v| head << "#{k}: #{v}\r\n" }
      head << "\r\n"
      @io.write(head)
    end

    def write(bytes)
      @io.write(bytes)
      @io.flush
    end

    # A whole answer with its length.
    def send(status, body, headers = {})
      body = body.b
      start(status, headers.merge("Content-Length" => body.bytesize.to_s))
      write(body)
    end

    # Cut the connection now (an answer that breaks mid-way).
    def reset
      @io.close
    rescue StandardError
      nil
    end
  end

  attr_reader :port, :path, :requests

  # @param kind [Symbol] :tcp, :tls or :unix
  def initialize(kind = :tcp, unix_path: nil, cert: nil, key: nil, &handler)
    @handler = handler
    @requests = Thread::Queue.new
    @log = []
    @lock = Mutex.new
    @kind = kind
    case kind
    when :unix
      @path = unix_path
      @server = UNIXServer.new(unix_path)
    else
      @tcp = TCPServer.new("127.0.0.1", 0)
      @port = @tcp.addr[1]
      if kind == :tls
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.cert = cert
        ctx.key = key
        @server = OpenSSL::SSL::SSLServer.new(@tcp, ctx)
        @server.start_immediately = false
      else
        @server = @tcp
      end
    end
    @threads = []
    @thread = Thread.new { accept_loop }
    @thread.report_on_exception = false
  end

  # Every request seen so far, in order.
  def log
    @lock.synchronize { @log.dup }
  end

  def clear_log
    @lock.synchronize { @log.clear }
  end

  def url(prefix = "/v1")
    scheme = @kind == :tls ? "https" : "http"
    "#{scheme}://127.0.0.1:#{@port}#{prefix}"
  end

  def close
    @thread.kill
    @threads.each(&:kill)
    @server.close
  rescue StandardError
    nil
  end

  private

  def accept_loop
    loop do
      sock = @server.accept
      t = Thread.new(sock) { |s| serve(s) }
      t.report_on_exception = false
      @threads << t
    end
  rescue StandardError
    nil
  end

  def serve(sock)
    sock.accept if sock.is_a?(OpenSSL::SSL::SSLSocket)
    req = read_request(sock)
    return if req.nil?

    @lock.synchronize { @log << req }
    res = Response.new(sock)
    begin
      @handler.call(req, res)
    rescue StandardError => e
      unless res.started?
        res.send(500, %({"error":{"kind":"failed","message":"mock: #{e.class}: #{e.message.gsub('"', "'")}","request_id":"req_x"}}),
                 "Content-Type" => "application/json")
      end
      warn "mock handler failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}" if ENV["MOCK_DEBUG"]
    end
  rescue StandardError
    nil
  ensure
    begin
      sock.close
    rescue StandardError
      nil
    end
  end

  def read_request(sock)
    line = sock.gets("\r\n")
    return nil if line.nil?

    method, target, = line.split
    headers = {}
    while (h = sock.gets("\r\n")) && h != "\r\n"
      k, v = h.split(":", 2)
      headers[k.strip.downcase] = v.to_s.strip
    end
    body = if headers["content-length"]
             n = headers["content-length"].to_i
             n.zero? ? "".b : read_exactly(sock, n)
           elsif headers["transfer-encoding"].to_s.include?("chunked")
             read_chunked(sock)
           else
             "".b
           end
    uri = URI.parse(target)
    query = URI.decode_www_form(uri.query.to_s).to_h
    Request.new(method, uri.path, query, headers, body)
  end

  def read_exactly(sock, n)
    buf = +"".b
    buf << sock.read(n - buf.bytesize) while buf.bytesize < n
    buf
  end

  def read_chunked(sock)
    buf = +"".b
    loop do
      size = sock.gets("\r\n").to_i(16)
      break if size.zero?

      buf << read_exactly(sock, size)
      sock.gets("\r\n")
    end
    sock.gets("\r\n")
    buf
  end
end

# A self-signed certificate for the TLS tests.
module TestCert
  module_function

  def generate(cn = "gaiadesk-123456789.local")
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(1 << 32)
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{cn}")
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    [cert, key]
  end
end
