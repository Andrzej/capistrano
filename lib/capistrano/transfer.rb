require 'net/scp'
require 'net/sftp'

require 'capistrano/processable'

module Capistrano
  class Transfer
    include Processable

    def self.process(direction, from, to, sessions, options={}, &block)
      new(direction, from, to, sessions, options, &block).process!
    end

    attr_reader :sessions
    attr_reader :options
    attr_reader :callback

    attr_reader :transport
    attr_reader :direction
    attr_reader :from
    attr_reader :to

    attr_reader :logger
    attr_reader :transfers

    def initialize(direction, from, to, sessions, options={}, &block)
      @direction = direction
      @from      = from
      @to        = to
      @sessions  = sessions
      @options   = options
      @callback  = callback

      @transport = options.fetch(:transport, :sftp)
      @logger    = options.delete(:logger)
      
      prepare_transfers
    end

    def process!
      loop do
        begin
          break unless process_iteration { active? }
        rescue Exception => error
          if error.respond_to?(:session)
            handle_error(error)
          else
            raise
          end
        end
      end

      failed = transfers.select { |txfr| txfr[:failed] }
      if failed.any?
        hosts = failed.map { |txfr| txfr[:server] }
        errors = failed.map { |txfr| "#{txfr[:error]} (#{txfr[:error].message})" }.uniq.join(", ")
        error = TransferError.new("#{operation} via #{transport} failed on #{hosts.join(',')}: #{errors}")
        error.hosts = hosts
        raise error
      end

      self
    end

    def active?
      transfers.any? { |transfer| transfer.active? }
    end

    def operation
      "#{direction}load"
    end

    private

      def prepare_transfers
        @session_map = {}

        @transfers = sessions.map do |session|
          session_from = normalize(from, session)
          session_to   = normalize(to, session)

          @session_map[session] = case transport
            when :sftp
              prepare_sftp_transfer(session_from, session_to, session)
            when :scp
              prepare_scp_transfer(session_from, session_to, session)
            else
              raise ArgumentError, "unsupported transport type: #{transport.inspect}"
            end
        end
      end

      def prepare_scp_transfer(from, to, session)
        scp = Net::SCP.new(session)

        channel = case direction
          when :up
            scp.upload(from, to, options, &callback)
          when :down
            scp.download(from, to, options, &callback)
          else
            raise ArgumentError, "unsupported transfer direction: #{direction.inspect}"
          end

        channel[:server]  = session.xserver
        channel[:host]    = session.xserver.host
        channel[:channel] = channel

        return channel
      end

      def prepare_sftp_transfer(from, to, session)
        # FIXME: connect! is a synchronous operation, do this async and then synchronize all at once
        sftp = Net::SFTP::Session.new(session).connect!

        real_callback = Proc.new do |event, op, *args|
          callback.call(event, op, *args) if callback
          op[:channel].close if event == :finish
        end

        operation = case direction
          when :up
            sftp.upload(from, to, options, &real_callback)
          when :down
            sftp.download(from, to, options, &real_callback)
          else
            raise ArgumentError, "unsupported transfer direction: #{direction.inspect}"
          end

        operation[:server]  = session.xserver
        operation[:host]    = session.xserver.host
        operation[:channel] = sftp.channel

        return operation
      end

      def normalize(argument, session)
        if argument.is_a?(String)
          argument.gsub(/\$CAPISTRANO:HOST\$/, session.xserver.host)
        elsif argument.respond_to?(:read)
          pos = argument.pos
          clone = StringIO.new(argument.read)
          clone.pos = argument.pos = pos
          clone
        else
          argument
        end
      end

      def handle_error(error)
        transfer = @session_map[error.session]
        transfer[:channel].close
        transfer[:error] = error
        transfer[:failed] = true

        transfer.abort! if transport == :sftp
      end
  end
end