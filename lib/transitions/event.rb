module Transitions
  # rubocop:disable Metrics/ClassLength
  class Event
    attr_reader :name, :success, :timestamp

    # :reek:TooManyStatements { max_statements: 13 }
    def initialize(machine, name, options = {}, &block)
      @machine = machine
      @name = name
      @transitions = []
      @timestamps = []
      if machine
        machine.klass.send(:define_method, "#{name}!") do |*args, **kwargs|
          machine.fire_event(name, self, true, *args, **kwargs)
        end

        machine.klass.send(:define_method, name.to_s) do |*args, **kwargs|
          machine.fire_event(name, self, false, *args, **kwargs)
        end

        machine.klass.send(:define_method, "can_#{name}?") do |*_args|
          machine.events_for(current_state).include?(name.to_sym)
        end

        machine.klass.send(:define_method, "can_execute_#{name}?") do |*args, **kwargs|
          event = name.to_sym

          send("can_#{name}?", *args, **kwargs) &&
            machine.events[event].can_execute_transition_from_state?(current_state, self, *args, **kwargs)
        end

        machine.klass.define_model_callbacks name, only: [:before, :after]
      end
      update(options, &block)
    end

    def fire(obj, to_state = nil, *args, **kwargs)
      transitions = @transitions.select { |t| t.from == obj.current_state || t.from == :ANY }
      fail InvalidTransition, error_message_for_invalid_transitions(obj) if transitions.size == 0

      next_state = nil
      transitions.each do |transition|
        next if to_state && !Array(transition.to).include?(to_state)
        next unless transition.executable?(obj, *args, **kwargs)

        next_state = to_state || Array(transition.to).first
        transition.execute(obj, *args, **kwargs)
        update_event_timestamp(obj, next_state) if timestamp_defined?
        break
      end
      # Update timestamps on obj if a timestamp has been defined
      next_state
    end

    def transitions_from_state?(state)
      @transitions.any? { |t| t.from? state }
    end

    def can_execute_transition_from_state?(state, obj, *args, **kwargs)
      @transitions.select { |t| t.from? state }.any? { |t| t.executable?(obj, *args, **kwargs) }
    end

    def ==(other)
      if other.is_a? Symbol
        name == other
      else
        name == other.name
      end
    end

    # Has the timestamp option been specified for this event?
    def timestamp_defined?
      !@timestamps.nil?
    end

    def update(options = {}, &block)
      @success       = build_success_callback(options[:success]) if options.key?(:success)
      self.timestamp = Array(options[:timestamp]) if options[:timestamp]
      instance_eval(&block) if block
      self
    end

    # update the timestamp attribute on obj
    def update_event_timestamp(obj, next_state)
      @timestamps.each do |timestamp|
        obj.public_send "#{timestamp_attribute_name(obj, next_state, timestamp)}=", Time.now
      end
    end

    # Set the timestamp attribute.
    # @raise [ArgumentError] timestamp should be either a String, Symbol or true
    def timestamp=(values)
      values.each do |value|
        case value
        when String, Symbol, TrueClass
          @timestamps << value
        else
          fail ArgumentError, 'timestamp must be either: true, a String or a Symbol'
        end
      end
    end

    private

    # Returns the name of the timestamp attribute for this event
    # If the timestamp was simply true it returns the default_timestamp_name
    # otherwise, returns the user-specified timestamp name
    def timestamp_attribute_name(obj, next_state, user_timestamp)
      user_timestamp == true ? default_timestamp_name(obj, next_state) : user_timestamp
    end

    # If @timestamp is true, try a default timestamp name
    def default_timestamp_name(obj, next_state)
      at_name = "#{next_state}_at"
      on_name = "#{next_state}_on"
      case
      when obj.respond_to?(at_name) then at_name
      when obj.respond_to?(on_name) then on_name
      else
        fail NoMethodError, "Couldn't find a suitable timestamp field for event: #{@name}.
          Please define #{at_name} or #{on_name} in #{obj.class}"
      end
    end

    def transitions(trans_opts)
      Array(trans_opts[:from]).each do |s|
        @transitions << StateTransition.new(trans_opts.merge(from: s.to_sym))
      end
    end

    def build_success_callback(callback_names)
      case callback_names
      when Array
        lambda do |record, *args|
          callback_names.each do |callback|
            build_success_callback(callback).call(record, *args)
          end
        end
      when Proc
        callback_names
      when Symbol
        ->(record, *args, **kwargs) { record.method(callback_names).arity == 0 ? record.send(callback_names) : record.send(callback_names, *args, **kwargs) }
      end
    end

    def error_message_for_invalid_transitions(obj)
      "Can't fire event `#{name}` in current state `#{obj.current_state}` for `#{obj.class.name}`"\
      " #{obj.respond_to?(:id) ? "with ID #{obj.id} " : nil}"
    end
  end
end
