module TakeoffTool

  # Predefined event names
  EVENT_CATEGORIES_CHANGED = :categories_changed
  EVENT_SCAN_COMPLETE      = :scan_complete
  EVENT_ASSIGNMENT_CHANGED = :assignment_changed
  EVENT_VISIBILITY_CHANGED = :visibility_changed
  EVENT_COLORS_CHANGED     = :colors_changed
  EVENT_ASSEMBLY_CREATED   = :assembly_created
  EVENT_ASSEMBLY_CHANGED   = :assembly_changed
  EVENT_ASSEMBLY_DELETED   = :assembly_deleted
  EVENT_PARTS_CHANGED      = :parts_changed

  @_event_subscribers ||= {}
  @_event_sub_counter ||= 0

  class << self
    # Subscribe to an event. Returns a subscription ID for later removal.
    def subscribe(event_name, &block)
      @_event_subscribers ||= {}
      @_event_sub_counter ||= 0
      @_event_sub_counter += 1
      sub_id = @_event_sub_counter
      @_event_subscribers[event_name] ||= {}
      @_event_subscribers[event_name][sub_id] = block
      sub_id
    end

    # Remove a listener by subscription ID.
    def unsubscribe(sub_id)
      @_event_subscribers ||= {}
      @_event_subscribers.each_value { |subs| subs.delete(sub_id) }
    end

    # Fire an event — calls all listeners, rescuing per-listener.
    def publish(event_name, **payload)
      @_event_subscribers ||= {}
      subs = @_event_subscribers[event_name]
      return unless subs
      subs.each do |id, block|
        begin
          block.call(payload)
        rescue => e
          puts "[FF EventBus] error in subscriber #{id} for #{event_name}: #{e.message}"
        end
      end
    end
  end

end
