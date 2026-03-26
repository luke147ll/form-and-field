module TakeoffTool
  module Highlighter
    unless defined?(COLORS)
    COLORS = ColorController::DEFAULT_COLORS
    end # unless defined?(COLORS)

    # ─── Color delegations to ColorController ───

    def self.highlight_all(sr, ca)
      ColorController.highlight_all(sr, ca)
    end

    def self.highlight_category(sr, ca, tc)
      ColorController.highlight_category(sr, ca, tc)
    end

    def self.highlight_single(eid)
      ColorController.highlight_single(eid)
    end

    def self.highlight_entities(ids)
      ColorController.highlight_entities(ids)
    end

    def self.highlight_category_color(sr, ca, cat_name)
      ColorController.highlight_category_color(sr, ca, cat_name)
    end

    def self.clear_category_color(sr, ca, cat_name)
      ColorController.clear_category_color(sr, ca, cat_name)
    end

    def self.clear_all
      ColorController.deactivate
    end

    def self.refresh_highlights
      ColorController.refresh_highlights
    end

    def self.clear_cached_material(cat)
      ColorController.clear_cached_material(cat)
    end

    def self.active_cat_colors
      ColorController.active_cat_colors
    end

    def self.highlights_active?
      ColorController.highlights_active?
    end

    # ─── Measurement visibility (all types use group.visible) ───

    def self.clear_measurement_highlights
      m = Sketchup.active_model; return unless m
      m.start_operation('Hide Measurement HL', true)
      hide_measurement_highlights_inner(m)
      m.commit_operation
    end

    # Non-destructive hide: hides all measurement groups (skip GRID tags — those toggle with gridlines)
    def self.hide_measurement_highlights_inner(m)
      hidden = 0
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        next unless mtype
        next if mtype == 'GRID' || mtype == 'CARD'
        if grp.visible?
          grp.visible = false
          hidden += 1
        end
        grp.set_attribute('TakeoffMeasurement', 'highlights_visible', false)
      end

      puts "Takeoff: Hid measurement highlights (#{hidden} groups hidden)" if hidden > 0
    end

    # ─── Measurement visibility controls ───

    def self.hide_measurement_highlights
      m = Sketchup.active_model; return unless m
      m.start_operation('Hide All Measurements', true)
      hide_measurement_highlights_inner(m)
      m.commit_operation
    end

    def self.show_all_measurement_highlights
      m = Sketchup.active_model; return unless m
      TakeoffTool.refresh_sf_material_colors rescue nil
      m.start_operation('Show All Measurements', true)
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        next unless mtype
        next if mtype == 'GRID' || mtype == 'CARD'
        grp.visible = true
        grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      end
      m.commit_operation
    end

    def self.hide_all_measurement_highlights
      m = Sketchup.active_model; return unless m
      m.start_operation('Hide All Measurements', true)
      hide_measurement_highlights_inner(m)
      m.commit_operation
    end

    def self.show_measurement_highlight(grp_eid)
      m = Sketchup.active_model; return unless m
      grp = TakeoffTool.find_entity(grp_eid.to_i)
      return unless grp && grp.valid?
      mtype = grp.get_attribute('TakeoffMeasurement', 'type')
      return unless mtype

      m.start_operation('Show Measurement', true)
      grp.visible = true
      grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      m.commit_operation
    end

    def self.hide_measurement_highlight(grp_eid)
      m = Sketchup.active_model; return unless m
      grp = TakeoffTool.find_entity(grp_eid.to_i)
      return unless grp && grp.valid?
      mtype = grp.get_attribute('TakeoffMeasurement', 'type')
      return unless mtype

      m.start_operation('Hide Measurement', true)
      grp.visible = false
      grp.set_attribute('TakeoffMeasurement', 'highlights_visible', false)
      m.commit_operation
    end

    def self.delete_measurement(grp_eid)
      m = Sketchup.active_model; return unless m
      grp = TakeoffTool.find_entity(grp_eid.to_i)
      return unless grp && grp.valid?

      m.start_operation('Delete Measurement', true)

      # Remove from registries
      eid = grp.entityID
      TakeoffTool.entity_registry.delete(eid)
      TakeoffTool.scan_results.reject! { |r| r[:entity_id] == eid }
      TakeoffTool.category_assignments.delete(eid)
      TakeoffTool.cost_code_assignments.delete(eid)

      # Erase the group
      grp.erase! if grp.valid?
      m.commit_operation
      puts "Takeoff: Deleted measurement eid=#{eid}"
    end

    # ─── Combine ───

    def self.combine_measurements(target_eid, source_eid)
      m = Sketchup.active_model
      return unless m
      target = TakeoffTool.find_entity(target_eid.to_i)
      source = TakeoffTool.find_entity(source_eid.to_i)
      return unless target && source && target.valid? && source.valid?

      tt = target.get_attribute('TakeoffMeasurement', 'type')
      st = source.get_attribute('TakeoffMeasurement', 'type')
      return unless tt && tt == st

      m.start_operation('Combine Measurements', true)

      target_inv = target.transformation.inverse
      source_xform = source.transformation
      target_mat = target.entities.grep(Sketchup::Face).first&.material

      begin
        case tt
        when 'SF', 'LF'
          source.entities.grep(Sketchup::Face).each do |face|
            world_pts = face.outer_loop.vertices.map { |v| source_xform * v.position }
            local_pts = world_pts.map { |p| target_inv * p }
            begin
              nf = target.entities.add_face(local_pts)
              if nf && target_mat
                nf.material = target_mat
                nf.back_material = target_mat
              end
            rescue => e
              puts "Combine: face copy error: #{e.message}"
            end
          end

        when 'VOL', 'COUNT', 'WALL'
          source.entities.grep(Sketchup::Group).each do |marker|
            next unless marker.valid?
            marker_xform = source_xform * marker.transformation
            new_marker = target.entities.add_group
            new_marker.entities.add_cpoint(ORIGIN)
            marker.attribute_dictionaries&.each do |dict|
              dict.each { |k, v| new_marker.set_attribute(dict.name, k, v) }
            end
            marker.entities.grep(Sketchup::Face).each do |face|
              world_pts = face.outer_loop.vertices.map { |v| marker_xform * v.position }
              local_pts = world_pts.map { |p| target_inv * p }
              begin
                nf = new_marker.entities.add_face(local_pts)
                if nf
                  nf.material = target_mat || face.material
                  nf.back_material = target_mat || face.back_material
                end
              rescue; end
            end
            marker.entities.grep(Sketchup::ConstructionPoint).each do |cp|
              world_pt = marker_xform * cp.position
              local_pt = target_inv * world_pt
              new_marker.entities.add_cpoint(local_pt) rescue nil
            end
          end
        end

        # Reassign derived parts referencing source → target
        require 'json'
        dp_json = m.get_attribute('FormAndField', 'derived_parts')
        if dp_json && !dp_json.empty?
          parts = JSON.parse(dp_json) rescue {}
          changed = false
          src_eid = source.entityID
          tgt_eid = target.entityID
          parts.each do |_id, part|
            if (part['sourceEid'] || 0).to_i == src_eid
              part['sourceEid'] = tgt_eid
              changed = true
            end
            if (part['parentMeasEid'] || 0).to_i == src_eid
              part['parentMeasEid'] = tgt_eid
              changed = true
            end
          end
          m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts)) if changed
        end

        recompute_measurement_totals(target)

        s_eid = source.entityID
        TakeoffTool.entity_registry.delete(s_eid)
        TakeoffTool.scan_results.reject! { |r| r[:entity_id] == s_eid } rescue nil
        TakeoffTool.category_assignments.delete(s_eid) rescue nil
        TakeoffTool.cost_code_assignments.delete(s_eid) rescue nil
        source.erase! if source.valid?

        m.commit_operation
        puts "Takeoff: Combined measurement #{source_eid} into #{target_eid}"
      rescue => e
        m.abort_operation
        puts "Takeoff: Combine error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      end
    end

    def self.recompute_measurement_totals(grp)
      return unless grp && grp.valid?
      tt = grp.get_attribute('TakeoffMeasurement', 'type')
      label = grp.get_attribute('TakeoffMeasurement', 'label') ||
              grp.get_attribute('TakeoffMeasurement', 'category') || ''
      case tt
      when 'SF'
        faces = grp.entities.grep(Sketchup::Face)
        total = (faces.sum { |f| f.area } / 144.0).round(2)
        grp.set_attribute('TakeoffMeasurement', 'total_sf', total)
        grp.set_attribute('TakeoffMeasurement', 'face_count', faces.length)
        grp.name = "TO_SF: #{label} — #{total} SF"
      when 'LF'
        faces = grp.entities.grep(Sketchup::Face)
        total_in = faces.sum { |f| f.area / 1.5 }
        total_ft = (total_in / 12.0).round(2)
        grp.set_attribute('TakeoffMeasurement', 'total_ft', total_ft)
        grp.set_attribute('TakeoffMeasurement', 'total_inches', total_in.round(2))
        grp.set_attribute('TakeoffMeasurement', 'segment_count', faces.length)
        grp.name = "TO_LF: #{label} — #{total_ft} LF"
      when 'VOL'
        markers = grp.entities.grep(Sketchup::Group).select { |g|
          g.valid? && g.get_attribute('VOL_Marker', 'volume_cy')
        }
        total_cy = markers.sum { |g| (g.get_attribute('VOL_Marker', 'volume_cy') || 0).to_f }.round(4)
        grp.set_attribute('TakeoffMeasurement', 'total_cy', total_cy)
        grp.set_attribute('TakeoffMeasurement', 'object_count', markers.length)
        grp.name = "TO_VOL: #{label} — #{'%.2f' % total_cy} CY"
      when 'COUNT'
        markers = grp.entities.grep(Sketchup::Group).select { |g|
          g.valid? && g.get_attribute('COUNT_Marker', 'placed')
        }
        grp.set_attribute('TakeoffMeasurement', 'total_count', markers.length)
        grp.name = "TO_COUNT: #{label} — #{markers.length} EA"
      when 'WALL'
        require 'json'
        segments = []
        grp.entities.grep(Sketchup::Group).each do |marker|
          next unless marker.valid? && marker.get_attribute('WALL_Segment', 'placed')
          segments << {
            'length_in' => (marker.get_attribute('WALL_Segment', 'length_in') || 0).to_f,
            'length_ft' => (marker.get_attribute('WALL_Segment', 'length_in') || 0).to_f / 12.0,
            'height_in' => (marker.get_attribute('WALL_Segment', 'height_in') || 0).to_f,
            'thickness_in' => (marker.get_attribute('WALL_Segment', 'thickness_in') || 0).to_f,
            'nominal' => marker.get_attribute('WALL_Segment', 'nominal') || ''
          }
        end
        total_lf = segments.sum { |s| (s['length_ft'] || 0).to_f }.round(2)
        grp.set_attribute('TakeoffMeasurement', 'wall_segments_json', JSON.generate(segments))
        grp.set_attribute('TakeoffMeasurement', 'total_lf', total_lf)
        grp.set_attribute('TakeoffMeasurement', 'segment_count', segments.length)
        grp.name = "TO_WALL: #{label} — #{'%.1f' % total_lf} LF"
      end
      grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
    end

    # ─── Visibility ───

    def self.collect_ancestors(entity)
      ancestors = []
      layers    = []
      current   = entity

      while current
        if current.respond_to?(:layer) && current.layer
          layers << current.layer
        end

        parent = current.respond_to?(:parent) ? current.parent : nil
        break unless parent

        if parent.is_a?(Sketchup::ComponentDefinition)
          parent.instances.each do |inst|
            ancestors << inst
            layers << inst.layer if inst.respond_to?(:layer) && inst.layer
          end
          current = parent.instances.first
        elsif parent.is_a?(Sketchup::Model)
          break
        else
          current = parent
        end
      end

      [ancestors, layers]
    end

    def self.ensure_ancestors_visible(visible_entities, m)
      ancestor_ids = {}
      ancestor_layer_names = { 'Layer0' => true, 'Untagged' => true }
      visible_entities.each do |e|
        ancs, lyrs = collect_ancestors(e)
        ancs.each { |a| ancestor_ids[a.entityID] = a }
        lyrs.each { |l| ancestor_layer_names[l.name] = true }
      end
      ancestor_ids.each_value do |a|
        a.visible = true if a.valid? && !a.visible?
      end
      ancestor_layer_names.each_key do |ln|
        l = m.layers[ln]
        l.visible = true if l && !l.visible?
      end
    end

    private

    # Returns true for groups that have their own visibility controls
    # and should not be touched by show_all/isolate/hide_category.
    def self.cad_or_grid?(e)
      return false unless e.is_a?(Sketchup::Group)
      return true if e.get_attribute('FF_CadOverlay', 'sheet_name')
      return true if e.get_attribute('TakeoffGridline', 'label')
      return true if e.get_attribute('TakeoffMeasurement', 'type')
      false
    rescue
      false
    end

    def self.build_keep_visible_set(visible_entities)
      keep_ids = {}
      keep_layers = { 'Layer0' => true, 'Untagged' => true }

      visible_entities.each do |e|
        keep_ids[e.entityID] = e
        if e.respond_to?(:layer) && e.layer
          keep_layers[e.layer.name] = true
        end
        ancs, lyrs = collect_ancestors(e)
        ancs.each { |a| keep_ids[a.entityID] = a }
        lyrs.each { |l| keep_layers[l.name] = true }
      end

      [keep_ids, keep_layers]
    end

    def self.show_hierarchy(ents)
      ents.each do |e|
        next unless e.valid?
        if e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          next if cad_or_grid?(e)
          e.visible = true unless e.visible?
          defn = e.respond_to?(:definition) ? e.definition : nil
          show_hierarchy(defn.entities) if defn
        end
      end
    end
  end
end
