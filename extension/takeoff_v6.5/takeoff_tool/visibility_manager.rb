module TakeoffTool
  class VisibilityManager

    # ── State ──
    @isolation_active = false
    @isolated_entity_ids = Set.new
    @hidden_entity_ids = Set.new
    @isolation_source = nil
    # Category map snapshot: category_name => true, used by on_category_changed
    @isolated_categories = nil

    class << self
      attr_reader :isolation_active, :isolated_entity_ids, :hidden_entity_ids, :isolation_source

      def isolated?
        @isolation_active
      end

      # ── isolate ──
      # Hide all scan entities except those in entity_ids.
      # Resolves ancestors via Highlighter, respects multiverse layers.
      def isolate(entity_ids, source: "scan")
        m = Sketchup.active_model; return unless m

        id_set = entity_ids.is_a?(Set) ? entity_ids : Set.new(entity_ids)

        # Resolve to actual entities
        visible = []
        id_set.each do |eid|
          e = TakeoffTool.find_entity(eid)
          visible << e if e && e.valid?
        end

        if visible.empty?
          puts "VisibilityManager: WARNING — no entities matched, skipping isolate"
          return
        end

        keep_ids, keep_layers = Highlighter.build_keep_visible_set(visible)

        m.start_operation('Isolate', true)

        # Hide all scan entities not in keep set
        (TakeoffTool.filtered_scan_results || []).each do |r|
          e = TakeoffTool.find_entity(r[:entity_id])
          next unless e && e.valid?
          e.visible = !!keep_ids[e.entityID]
        end

        # Show ancestors
        keep_ids.each_value { |a| a.visible = true if a.valid? && !a.visible? }

        # Force layers visible (respecting multiverse)
        mv_view = TakeoffTool.active_mv_view rescue nil
        keep_layers.each_key do |ln|
          next if mv_view == 'a' && ln == 'FF_Model_B'
          next if mv_view == 'b' && ln == 'FF_Model_A'
          l = m.layers[ln]
          l.visible = true if l && !l.visible?
        end

        m.commit_operation

        @isolation_active = true
        @isolation_source = source.to_s
        @isolated_entity_ids = id_set
        @hidden_entity_ids = Set.new
        @isolated_categories = nil

        puts "VisibilityManager: isolated #{visible.length} entities (source=#{source})"
        TakeoffTool.publish(TakeoffTool::EVENT_VISIBILITY_CHANGED, source: source, action: :isolate)
      end

      # ── hide ──
      # Incrementally hide entities. Routes measurements through their own
      # visibility system. Checks for scan children before hiding containers.
      def hide(entity_ids)
        m = Sketchup.active_model; return unless m

        ids = entity_ids.is_a?(Array) ? entity_ids : entity_ids.to_a
        scan_eid_set = Set.new((TakeoffTool.scan_results || []).map { |r| r[:entity_id] })
        hide_set = Set.new(ids)
        meas_changed = false

        m.start_operation('Hide', true)
        ids.each do |eid|
          e = TakeoffTool.find_entity(eid)
          next unless e && e.valid?

          # Route measurement entities through Highlighter
          if e.is_a?(Sketchup::Group) && e.get_attribute('TakeoffMeasurement', 'type')
            mtype = e.get_attribute('TakeoffMeasurement', 'type')
            if mtype == 'LF' || mtype == 'ELEV' || mtype == 'BENCHMARK' || mtype == 'NOTE'
              e.visible = false
            elsif mtype == 'SF'
              Highlighter.hide_sf_measurement_faces(m, e)
            end
            e.set_attribute('TakeoffMeasurement', 'highlights_visible', false)
            meas_changed = true
          else
            # Part groups: hide directly
            is_part = (e.get_attribute('FormAndField', 'is_part') rescue nil) == true
            unless is_part
              # Don't hide if this entity contains scan children that should stay visible
              if e.respond_to?(:definition) && Dashboard._has_visible_scan_child?(e.definition, scan_eid_set, hide_set)
                next
              end
            end
            e.visible = false
            @hidden_entity_ids.add(eid)
          end
        end
        m.commit_operation

        if meas_changed && defined?(Dashboard)
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        end
        TakeoffTool.publish(TakeoffTool::EVENT_VISIBILITY_CHANGED, action: :hide, count: ids.length)
      end

      # ── show ──
      # Show entities and ensure ancestors are visible.
      # Routes measurements through their own visibility system.
      def show(entity_ids)
        m = Sketchup.active_model; return unless m

        ids = entity_ids.is_a?(Array) ? entity_ids : entity_ids.to_a
        meas_changed = false
        regular = []

        m.start_operation('Show', true)
        ids.each do |eid|
          e = TakeoffTool.find_entity(eid)
          next unless e && e.valid?

          if e.is_a?(Sketchup::Group) && e.get_attribute('TakeoffMeasurement', 'type')
            mtype = e.get_attribute('TakeoffMeasurement', 'type')
            if mtype == 'LF' || mtype == 'ELEV' || mtype == 'BENCHMARK' || mtype == 'NOTE'
              e.visible = true
            elsif mtype == 'SF'
              Highlighter.show_sf_measurement_faces(m, e)
            end
            e.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
            meas_changed = true
          else
            e.visible = true
            regular << e
            @hidden_entity_ids.delete(eid)
          end
        end
        Highlighter.ensure_ancestors_visible(regular, m) if regular.any?
        m.commit_operation

        if meas_changed && defined?(Dashboard)
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        end
        TakeoffTool.publish(TakeoffTool::EVENT_VISIBILITY_CHANGED, action: :show, count: ids.length)
      end

      # ── show_all ──
      # Clears all isolation/hide state and shows everything.
      # Respects multiverse layer state.
      def show_all
        m = Sketchup.active_model; return unless m

        m.start_operation('Show All', true)

        TakeoffTool.entity_registry.each_value { |e| e.visible = true if e && e.valid? }
        Highlighter.show_hierarchy(m.entities)

        mv_view = TakeoffTool.active_mv_view rescue nil
        m.layers.each do |l|
          if mv_view == 'a' && l.name == 'FF_Model_B'
            l.visible = false
          elsif mv_view == 'b' && l.name == 'FF_Model_A'
            l.visible = false
          else
            l.visible = true
          end
        end

        m.commit_operation

        @isolation_active = false
        @isolation_source = nil
        @isolated_entity_ids = Set.new
        @hidden_entity_ids = Set.new
        @isolated_categories = nil

        TakeoffTool.publish(TakeoffTool::EVENT_VISIBILITY_CHANGED, action: :show_all)
      end

      # ── on_category_changed ──
      # When an entity is recategorized during active isolation,
      # determine whether it should be visible or hidden.
      def on_category_changed(eid, new_cat)
        return unless @isolation_active
        e = TakeoffTool.find_entity(eid)
        return unless e && e.valid?
        m = Sketchup.active_model
        return unless m

        # If we have a category-based isolation, check the category map
        if @isolated_categories
          should_show = !!@isolated_categories[new_cat]
        else
          # Entity-based isolation: check if eid is in the isolated set
          should_show = @isolated_entity_ids.include?(eid)
        end

        m.start_operation('Update Isolation', true)
        if should_show && !e.visible?
          e.visible = true
          Highlighter.ensure_ancestors_visible([e], m)
        elsif !should_show && e.visible?
          e.visible = false
        end
        m.commit_operation
      end

      # ── isolate_by_category ──
      # Convenience: isolate all entities matching one or more categories.
      # Stores the category map for on_category_changed.
      def isolate_by_category(categories, source: "scan")
        cat_set = categories.is_a?(Hash) ? categories : Array(categories).each_with_object({}) { |c, h| h[c] = true }
        sr = TakeoffTool.filtered_scan_results || []
        ca = TakeoffTool.category_assignments || {}

        ids = []
        sr.each do |r|
          cat = ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
          ids << r[:entity_id] if cat_set[cat]
        end

        if ids.empty?
          puts "VisibilityManager: WARNING — no entities matched categories #{cat_set.keys.first(5).inspect}, skipping isolate"
          return
        end

        isolate(ids, source: source)
        @isolated_categories = cat_set
      end

      # ── reset ──
      # Clears internal state without touching the viewport.
      # Used when a new scan replaces all data.
      def reset
        @isolation_active = false
        @isolation_source = nil
        @isolated_entity_ids = Set.new
        @hidden_entity_ids = Set.new
        @isolated_categories = nil
      end
    end
  end

  # Subscribe to category reassignment events
  subscribe(EVENT_ASSIGNMENT_CHANGED) do |payload|
    if payload[:key] == 'category' && VisibilityManager.isolated?
      VisibilityManager.on_category_changed(payload[:eid], payload[:value])
    end
  end
end
