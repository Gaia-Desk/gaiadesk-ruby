# frozen_string_literal: true

module GaiaDesk
  # Argument checks and the request bodies built from them (the contract's
  # +ExecSpec+, +JobSpec+, +MintSpec+). Pure; every failure is a {UsageError}.
  module Args
    # +exec+'s shells (+powershell+ is sent as +pwsh+).
    SHELLS = %w[default none sh bash zsh cmd pwsh powershell].freeze
    # A job's shells (never +none+ or +default+: a job is a command line).
    JOB_SHELLS = %w[sh bash zsh cmd pwsh powershell].freeze
    # The scopes an agent token can carry through the API.
    TOKEN_SCOPES = %w[exec shell cp forward jobs screen].freeze
    # A minted token's scopes when none are given.
    DEFAULT_SCOPES = %w[exec cp jobs].freeze
    UNITS = { "s" => 1, "sec" => 1, "secs" => 1, "m" => 60, "min" => 60, "mins" => 60, "h" => 3600, "d" => 86_400,
              "w" => 604_800 }.freeze

    module_function

    def usage(message)
      UsageError.new(message, kind: "usage")
    end

    # A desk id: one token, no whitespace, not a flag.
    def check_desk(desk_id)
      raise usage("a desk id is required") unless desk_id.is_a?(String) && !desk_id.strip.empty?

      d = desk_id.strip
      raise usage("not a desk id: #{desk_id.inspect}") if d.match?(/\s/) || d.start_with?("-")

      d
    end

    # A job name: letters, digits, <tt>. _ -</tt>, not starting with +-+.
    def check_job_name(name)
      unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9._][A-Za-z0-9._-]*\z/)
        raise usage("a job name is letters, digits, . _ - (not starting with -): #{name.inspect}")
      end

      name
    end

    # A duration as whole seconds: a number (rounded up), or <tt>"90"</tt>,
    # <tt>"30s"</tt>, <tt>"10m"</tt>, <tt>"1h30m"</tt>, <tt>"7d"</tt>, <tt>"2w"</tt>.
    # @return [Integer]
    def seconds(value, what)
      case value
      when Integer, Float
        raise usage("#{what} must be a number of seconds >= 0") if !value.finite? || value.negative?

        value.ceil
      when String
        d = value.strip
        raise usage("#{what}: not a duration: #{value.inspect}") unless d.match?(/\A\d+\s*[a-zA-Z]*(\s*\d+\s*[a-zA-Z]+)*\z/)
        return d.to_i if d.match?(/\A\d+\z/)

        d.scan(/(\d+)\s*([a-zA-Z]+)/).sum do |n, unit|
          u = UNITS[unit.downcase] or raise usage("#{what}: unknown unit in #{value.inspect}")
          n.to_i * u
        end
      else
        raise usage("#{what} must be a number of seconds or a duration string")
      end
    end

    # The shell's name as sent: +powershell+ is +pwsh+.
    def wire_shell(shell, job: false)
      s = shell.to_s
      allowed = job ? JOB_SHELLS : SHELLS
      raise usage("#{job ? "a job's shell" : 'shell'} is one of #{allowed.join(', ')}") unless allowed.include?(s)

      s == "powershell" ? "pwsh" : s
    end

    # +env+: environment variables for the command, <tt>{NAME => value}</tt>. A name
    # is non-empty, without +=+, whitespace or NUL; a value is a String without NUL.
    # Errors name the variable, never its value.
    def check_env(env)
      return nil if env.nil?
      raise usage("env is a Hash of variable names to values") unless env.is_a?(Hash)

      env.each_with_object({}) do |(k, v), out|
        k = k.to_s if k.is_a?(Symbol)
        unless k.is_a?(String) && !k.empty? && !k.include?("=") && !k.include?("\0") && !k.match?(/\s/)
          raise usage("env: #{k.inspect} is not an environment variable name")
        end
        raise usage("env: the value of #{k} must be a String") unless v.is_a?(String)
        raise usage("env: the value of #{k} contains a NUL byte") if v.include?("\0")

        out[k] = v
      end
    end

    # +mem+: megabytes, or <tt>"512M"</tt> / <tt>"4G"</tt>.
    def mem_mb(mem)
      return mem if mem.is_a?(Integer)

      m = mem.to_s.match(/\A\s*(\d+)\s*([MGmg])?[Bb]?\s*\z/) or raise usage("mem: not a size: #{mem.inspect}")
      m[1].to_i * (m[2].to_s.upcase == "G" ? 1024 : 1)
    end

    def command_list(command, what)
      argv = command.is_a?(String) ? [command] : Array(command).map(&:to_s)
      raise usage("#{what} needs a command") if argv.empty? || (argv.size == 1 && argv[0].strip.empty?)

      argv
    end

    # An +ExecSpec+: +command+ (a String, one line for the desk's shell) or +argv+
    # (an Array, separate arguments), and +shell+, +env+, +cwd+, +timeout_secs+,
    # +stdin+.
    def exec_spec(command, stdin: nil, shell: nil, env: nil, cwd: nil, timeout: nil)
      argv = command_list(command, "exec")
      spec = command.is_a?(String) ? { "command" => command } : { "argv" => argv }
      spec["shell"] = wire_shell(shell) unless shell.nil?
      spec["env"] = check_env(env) unless env.nil?
      spec["cwd"] = cwd.to_s unless cwd.nil?
      spec["timeout_secs"] = seconds(timeout, "timeout") unless timeout.nil?
      spec["stdin"] = stdin_text(stdin) unless stdin.nil?
      spec
    end

    # stdin as the text an ExecSpec carries: a String, or an IO read to its end.
    def stdin_text(stdin)
      data = stdin.respond_to?(:read) ? stdin.read : stdin
      raise usage("stdin is a String or an IO") unless data.is_a?(String)

      data.dup.force_encoding(Encoding::UTF_8).scrub("\uFFFD")
    end

    # A +JobSpec+.
    def job_spec(name, command, priority: nil, cpu: nil, mem: nil, keep_awake: nil, cwd: nil, shell: nil, env: nil)
      check_job_name(name)
      limits = {}
      limits["priority"] = priority.to_s unless priority.nil?
      limits["cpu_percent"] = Integer(cpu) unless cpu.nil?
      limits["mem_mb"] = mem_mb(mem) unless mem.nil?
      limits["keep_awake"] = keep_awake ? true : false unless keep_awake.nil?
      spec = { "name" => name, "command" => command_list(command, "run_job"), "limits" => limits }
      spec["cwd"] = cwd.to_s unless cwd.nil?
      spec["shell"] = wire_shell(shell, job: true) unless shell.nil?
      spec["env"] = check_env(env) unless env.nil?
      spec
    end

    # A +MintSpec+.
    def mint_spec(name:, expires: nil, scopes: nil, cwd: nil, low_priv: false)
      raise usage("create_token needs a name") if name.nil? || name.to_s.strip.empty?

      list = scopes.nil? || Array(scopes).empty? ? DEFAULT_SCOPES.dup : Array(scopes).map(&:to_s)

      spec = { "name" => name.to_s, "expires_secs" => seconds(expires || "7d", "expires"), "scopes" => list }
      spec["cwd"] = cwd.to_s unless cwd.nil?
      spec["low_priv"] = true if low_priv
      spec
    end
  end
end
