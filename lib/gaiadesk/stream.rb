# frozen_string_literal: true

require "json"

module GaiaDesk
  # One piece of output: +stream+ is <tt>"stdout"</tt> or <tt>"stderr"</tt> (a
  # followed job's output is <tt>"stdout"</tt>), +data+ its bytes (binary String).
  Chunk = Struct.new(:stream, :data) do
    # The bytes as UTF-8 text (invalid sequences replaced).
    def text
      data.dup.force_encoding(Encoding::UTF_8).scrub("\uFFFD")
    end
  end

  # How a stream ended: +exit_code+ is what +gaiadesk-cli+ would have exited with
  # (the command's own code for exec; 0 for a log that ended; 130 stopped with
  # {Stream#kill}; 254 refused; 255 an error), +message+ a line about it.
  Exit = Struct.new(:exit_code, :message)

  # An incremental <tt>text/event-stream</tt> parser over bytes (fields, +:+
  # comments, blank-line dispatch; an event may be split anywhere, even between
  # +\r+ and +\n+). Lines are split on bytes, so a character split across reads
  # is whole again before it is decoded.
  class SseParser
    # One event: its name (+message+ when it has none) and its data.
    Event = Struct.new(:event, :data)

    def initialize
      @buf = "".b
      @event = ""
      @data = []
    end

    # The events +bytes+ completes.
    # @return [Array<Event>]
    def feed(bytes)
      @buf << bytes.b
      out = []
      while (i = @buf.index(/\r\n|\r|\n/n))
        nl = @buf[i] == "\r" && @buf[i + 1] == "\n" ? 2 : 1
        break if @buf[i] == "\r" && i == @buf.bytesize - 1 # maybe half of \r\n: wait for the next read

        line = @buf.byteslice(0, i)
        @buf = @buf.byteslice(i + nl, @buf.bytesize - i - nl)
        ev = parse_line(line.force_encoding(Encoding::UTF_8).scrub("\uFFFD"))
        out << ev if ev
      end
      out
    end

    # The end of the stream: an event not finished with a blank line is still delivered.
    # @return [Array<Event>]
    def finish
      out = []
      unless @buf.empty?
        l = @buf.sub(/\r\z/n, "")
        @buf = "".b
        ev = parse_line(l.force_encoding(Encoding::UTF_8).scrub("\uFFFD"))
        out << ev if ev
      end
      ev = parse_line("")
      out << ev if ev
      out
    end

    private

    def parse_line(text)
      if text.empty?
        if @data.empty?
          @event = ""
          return nil
        end
        ev = Event.new(@event.empty? ? "message" : @event, @data.join("\n"))
        @event = ""
        @data = []
        return ev
      end
      return nil if text.start_with?(":")

      field, sep, value = text.partition(":")
      value = "" if sep.empty?
      value = value[1..] if value.start_with?(" ")
      case field
      when "event" then @event = value
      when "data" then @data << value
      end
      nil
    end
  end

  # A streamed operation's output as it is produced: <tt>exec_stream</tt>'s
  # +stdout+ / +stderr+, <tt>follow_job_logs</tt>' output. Read on a thread from
  # the API's Server-Sent Events into {Chunk}s; {#wait} for the {Exit}; {#result}
  # is the last event (+exit+ / +error+ for exec, +end+ / +interrupted+ / +error+
  # for logs), the same objects as <tt>gaiadesk-cli --json-stream</tt> prints.
  #
  # Enumerable over its chunks:
  #
  #   s = gd.exec_stream(desk, "make test")
  #   s.each { |c| print c.text }
  #   s.wait.exit_code
  #
  # Every chunk is delivered once, to whoever reads it first ({#each},
  # {#next_chunk}, {#text}).
  class Stream
    include Enumerable

    # Raised in the reading thread by {Stream#kill}.
    class Killed < StandardError; end

    # @return [Array<String>] the operation (<tt>["POST /desks/123456789/exec"]</tt>)
    attr_reader :argv

    # @param op [String] the request, for errors
    # @param kind [String] +exec+ or +logs+
    # @param job_name [String] the job, for logs' messages
    # @yield [on_response] runs the request; calls +on_response.call(response, mapper)+ with the open
    #   Net::HTTPResponse (and, for a sealed stream, its event mapper)
    def initialize(op, kind, job_name = "", &start)
      @argv = [op]
      @kind = kind
      @job = job_name
      @queue = Thread::Queue.new
      @result = nil
      @drained = false
      @killed = false
      @exit = Exit.new(nil, "")
      @mapper = nil
      @thread = Thread.new { pump(start) }
      @thread.report_on_exception = false
    end

    # The last event (a Hash): waits for the stream to end. +nil+ when it was killed.
    def result
      @thread.join
      @result
    end

    # Each chunk, as it arrives, until the stream ends (blocking). Without a block, an Enumerator.
    # @yieldparam chunk [Chunk]
    def each
      return enum_for(:each) unless block_given?

      while (c = next_chunk)
        yield c
      end
      self
    end

    # The next chunk (blocking), or +nil+ at the end.
    # @return [Chunk, nil]
    def next_chunk
      return nil if @drained

      c = @queue.pop
      @drained = true if c.nil?
      c
    end

    # <tt>[stream, text]</tt> pairs. Without a block, an Enumerator.
    def text
      return enum_for(:text) unless block_given?

      each { |c| yield c.stream, c.text }
    end

    # Everything the stream sends, read to its end: <tt>{"stdout" => String, "stderr" => String}</tt>.
    def read_all
      out = { "stdout" => +"", "stderr" => +"" }
      each { |c| out[c.stream] << c.text }
      out
    end

    # stdin is given up front over the HTTP API (+stdin:+); a stream cannot be written to.
    def write(_data)
      raise UsageError.new("stdin cannot be written to a command over the HTTP API (give stdin: up front)",
                           kind: "usage", argv: @argv)
    end

    # stdin is closed from the start over the API.
    def close_write; end

    # Stop: closes the request. The server stops the command (exec), or stops
    # following (logs: the job goes on).
    def kill
      @killed = true
      @thread.raise(Killed, "stopped") if @thread.alive?
      self
    end
    alias cancel kill

    # Block until the stream ends (at most +timeout+ seconds).
    # @return [Exit] how it ended (+exit_code+ +nil+ while it still runs after +timeout+)
    def wait(timeout = nil)
      @thread.join(timeout)
      @exit
    end

    # The {Exit}'s code, once it ended.
    def exit_code
      wait.exit_code
    end

    private

    def pump(start)
      start.call(lambda { |response, mapper|
        @mapper = mapper
        @exit = events(response)
      })
    rescue Killed
      @exit = Exit.new(130, "interrupted")
    rescue Error => e
      if @killed
        @exit = Exit.new(130, "interrupted")
      else
        error = error_object(e)
        @result = { "event" => "error", "exit" => e.exit_code || 255, "error" => error }
        @exit = Exit.new(e.exit_code || 255, error["message"])
      end
    rescue StandardError => e
      if @killed
        @exit = Exit.new(130, "interrupted")
      else
        message = "the GaiaDesk API stream failed: #{e.message}"
        @result = { "event" => "error", "exit" => 255, "error" => { "kind" => "unreachable", "reason" => "network", "message" => message } }
        @exit = Exit.new(255, message)
      end
    ensure
      @queue.push(nil)
    end

    def events(response)
      parser = SseParser.new
      done = nil
      response.read_body do |bytes|
        raise Killed, "stopped" if @killed

        parser.feed(bytes).each do |ev|
          done = on_sse(ev)
          break if done
        end
        break if done
      end
      return done if done

      parser.finish.each do |ev|
        done = on_sse(ev)
        return done if done
      end
      what = @kind == "exec" ? "command" : "job"
      message = "the event stream ended before the #{what} did"
      @result = { "event" => "error", "exit" => 255, "error" => { "kind" => "connection_lost", "message" => message } }
      Exit.new(255, message)
    end

    # One SSE event. In a sealed stream only +sealed+ events (opened, in order) and the
    # server's own plaintext +error+ (the desk lost mid-stream) count; anything else in
    # the clear, or a sealed event that does not open, ends the stream as a protocol error.
    def on_sse(sse)
      return on(object(sse)) if @mapper.nil? || sse.event == "error"

      begin
        raise E2E::OpenError.new("e2e_malformed", "the stream sent a #{sse.event.inspect} event in the clear") if sse.event != "sealed"

        mapped = @mapper.map(sse.data)
      rescue E2E::OpenError, Error => e
        message = "the end-to-end encrypted stream could not be read: #{e.message}"
        reason = e.respond_to?(:reason) && e.reason ? e.reason : "e2e_malformed"
        @result = { "event" => "error", "exit" => 255, "error" => { "kind" => "protocol", "reason" => reason, "message" => message } }
        return Exit.new(255, message)
      end
      mapped.each do |o|
        done = on(o)
        return done if done
      end
      nil
    end

    def object(sse)
      v = JSON.parse(sse.data)
      return nil unless v.is_a?(Hash)

      v["event"].is_a?(String) ? v : v.merge("event" => sse.event)
    rescue JSON::ParserError
      nil
    end

    def on(obj)
      return nil if obj.nil?

      kind = obj["event"]
      if @kind == "exec"
        on_exec(kind, obj)
      else
        on_logs(kind, obj)
      end
    end

    def on_exec(kind, obj)
      case kind
      when "stdout", "stderr"
        @queue.push(Chunk.new(kind, obj["data"].b)) if obj["data"].is_a?(String)
        nil
      when "exit", "error"
        @result = obj
        e = obj["error"]
        message = e.is_a?(Hash) && e["message"].is_a?(String) ? e["message"] : ""
        Exit.new(obj["exit"].is_a?(Integer) ? obj["exit"] : 255, message)
      end
    end

    def on_logs(kind, obj)
      case kind
      when "output"
        @queue.push(Chunk.new("stdout", obj["data"].b)) if obj["data"].is_a?(String)
        nil
      when "end"
        @result = obj
        job = obj["job"].is_a?(Hash) ? obj["job"] : {}
        name = job["name"] || @job
        return Exit.new(0, "job #{name} exited (exit #{job['exit_code']})") if job["exit_code"].is_a?(Integer)

        Exit.new(0, "job #{name} #{job['state'] || 'ended'}")
      when "interrupted"
        @result = obj
        Exit.new(0, "stopped following; the job goes on")
      when "error"
        e = obj["error"].is_a?(Hash) ? obj["error"] : { "kind" => "protocol", "message" => "the desk reported an error" }
        @result = { "event" => "error", "error" => e }
        Exit.new(Errors.exit_for(e["kind"]), e["message"].to_s)
      end
    end

    def error_object(err)
      env = Errors.envelope(err.json)
      if env
        out = { "kind" => env.kind, "message" => env.message.empty? ? err.message : env.message }
        out["reason"] = env.reason if env.reason
        out["desk"] = env.desk if env.desk
        return out
      end
      kind = Errors::CLASSES.find { |_, cls| err.is_a?(cls) }&.first ||
             { "network" => "unreachable", "e2e" => "protocol" }.fetch(err.kind, err.kind)
      out = { "kind" => kind, "message" => err.message }
      out["reason"] = err.reason if err.reason
      out
    end
  end
end
