# -*- ruby -*-
# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

module NewRelic
  module Agent
    class ErrorTraceAggregator
      def initialize(capacity)
        @capacity = capacity
        @lock = Mutex.new
        @errors = []
      end

      def merge!(errors)
        errors.each do |error|
          add_to_error_queue(error)
        end
      end

      # Get the errors currently queued up.  Unsent errors are left
      # over from a previous unsuccessful attempt to send them to the server.
      def harvest!
        @lock.synchronize do
          errors = @errors
          @errors = []
          errors
        end
      end

      def reset!
        @lock.synchronize do
          @errors = []
        end
      end

      # Synchronizes adding an error to the error queue, and checks if
      # the error queue is too long - if so, we drop the error on the
      # floor after logging a warning.
      def add_to_error_queue(noticed_error)
        @lock.synchronize do
          if !over_queue_limit?(noticed_error.message) && !@errors.include?(noticed_error)
            @errors << noticed_error
          end
        end
      end

      # checks the size of the error queue to make sure we are under
      # the maximum limit, and logs a warning if we are over the limit.
      def over_queue_limit?(message)
        over_limit = (@errors.reject{|err| err.is_internal}.length >= @capacity)
        ::NewRelic::Agent.logger.warn("The error reporting queue has reached #{@capacity}. The error detail for this and subsequent errors will not be transmitted to New Relic until the queued errors have been sent: #{message}") if over_limit
        over_limit
      end

      def errors
        @lock.synchronize{ @errors }
      end

      # *Use sparingly for difficult to track bugs.*
      #
      # Track internal agent errors for communication back to New Relic.
      # To use, make a specific subclass of NewRelic::Agent::InternalAgentError,
      # then pass an instance of it to this method when your problem occurs.
      #
      # Limits are treated differently for these errors. We only gather one per
      # class per harvest, disregarding (and not impacting) the app error queue
      # limit.
      def notice_agent_error(exception)
        return unless exception.class < NewRelic::Agent::InternalAgentError

        # Log 'em all!
        NewRelic::Agent.logger.info(exception)

        @lock.synchronize do
          # Already seen this class once? Bail!
          return if @errors.any? { |err| err.exception_class_name == exception.class.name }

          trace = exception.backtrace || caller.dup
          noticed_error = NewRelic::NoticedError.new("NewRelic/AgentError", exception)
          noticed_error.stack_trace = trace
          @errors << noticed_error
        end
      rescue => e
        NewRelic::Agent.logger.info("Unable to capture internal agent error due to an exception:", e)
      end
    end
  end
end
