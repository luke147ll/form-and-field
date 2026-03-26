module TakeoffTool
  class GridlineSystem
    GRID_LAYER = 'FF_Gridlines' unless defined?(GRID_LAYER)
    GRID_DICT = 'TakeoffGridline' unless defined?(GRID_DICT)

    @gridlines = {}

    # Creates ONLY the grid plane geometry (no circle tag — the annotation tag tool handles that).
    # If ref is provided, uses the reference line to size the plane.
    # Otherwise falls back to model bounds with a small margin.
    def self.create_grid_plane(axis, position, label, click_point, ref = nil)
      model = Sketchup.active_model
      return nil unless model

      model.start_operation("Grid Plane #{label}", true)

      layer = model.layers[GRID_LAYER] || model.layers.add(GRID_LAYER)
      grp = model.active_entities.add_group
      grp.layer = layer
      grp.name = "FF_GridPlane: #{label}"
      ents = grp.entities

      if ref
        # Use reference line to determine extent
        ref_start = ref[:start]
        ref_end = ref[:end_pt]

        # Fixed 20' (240") depth below the reference line top
        z_max = [ref_start.z, ref_end.z].max
        z_min = z_max - 240

        if axis == :x
          # Grid perpendicular to X — reference line defines Y span
          y_min = [ref_start.y, ref_end.y].min
          y_max = [ref_start.y, ref_end.y].max

          p1 = Geom::Point3d.new(position, y_min, z_min)
          p2 = Geom::Point3d.new(position, y_min, z_max)
          p3 = Geom::Point3d.new(position, y_max, z_max)
          p4 = Geom::Point3d.new(position, y_max, z_min)
        else
          # Grid perpendicular to Y — reference line defines X span
          x_min = [ref_start.x, ref_end.x].min
          x_max = [ref_start.x, ref_end.x].max

          p1 = Geom::Point3d.new(x_min, position, z_min)
          p2 = Geom::Point3d.new(x_min, position, z_max)
          p3 = Geom::Point3d.new(x_max, position, z_max)
          p4 = Geom::Point3d.new(x_max, position, z_min)
        end
      else
        # Fallback — fixed 20' depth, model bounds for width
        margin = 60
        bb = model.bounds
        z_max = click_point.z
        z_min = z_max - 240

        if axis == :x
          y_min = bb.min.y - margin
          y_max = bb.max.y + margin
          p1 = Geom::Point3d.new(position, y_min, z_min)
          p2 = Geom::Point3d.new(position, y_min, z_max)
          p3 = Geom::Point3d.new(position, y_max, z_max)
          p4 = Geom::Point3d.new(position, y_max, z_min)
        else
          x_min = bb.min.x - margin
          x_max = bb.max.x + margin
          p1 = Geom::Point3d.new(x_min, position, z_min)
          p2 = Geom::Point3d.new(x_min, position, z_max)
          p3 = Geom::Point3d.new(x_max, position, z_max)
          p4 = Geom::Point3d.new(x_max, position, z_min)
        end
      end

      # Clean rectangle — just edges, no diagonals
      ents.add_edges(p1, p2)
      ents.add_edges(p2, p3)
      ents.add_edges(p3, p4)
      ents.add_edges(p4, p1)

      # Create face for transparent red plane
      face = ents.add_face(p1, p2, p3, p4)
      if face
        mat_name = 'FF_Grid_Plane'
        mat = model.materials[mat_name] || begin
          m = model.materials.add(mat_name)
          m.color = Sketchup::Color.new(255, 80, 80)
          m.alpha = 0.15
          m
        end
        face.material = mat
        face.back_material = mat
      end

      # Store attributes
      require 'json'
      grp.set_attribute(GRID_DICT, 'axis', axis.to_s)
      grp.set_attribute(GRID_DICT, 'position', position.to_f)
      grp.set_attribute(GRID_DICT, 'label', label.to_s)
      grp.set_attribute(GRID_DICT, 'type', 'plane')

      model.commit_operation

      @gridlines[label] = { group_eid: grp.entityID, axis: axis, position: position, label: label }
      puts "GridlineSystem: Created plane '#{label}' at #{axis}=#{(position / 12.0).round(2)}'"
      Dashboard.invalidate_measurement_cache rescue nil
      grp
    end

    def self.create_grid_set(axis, start_position, spacing, count, labels = nil)
      results = []
      count.times do |i|
        pos = start_position + (i * spacing)
        lbl = if labels && labels[i]
          labels[i]
        elsif axis == :x
          (i + 1).to_s
        else
          ('A'.ord + i).chr
        end
        grp = create_grid_plane(axis, pos, lbl, Geom::Point3d.new(0, 0, 0))
        results << { label: lbl, position: pos, position_ft: (pos / 12.0).round(2), eid: grp ? grp.entityID : nil }
      end
      results
    end

    def self.delete_gridline(label)
      model = Sketchup.active_model
      return false unless model
      model.start_operation("Delete Grid #{label}", true)
      model.active_entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        next unless grp.get_attribute(GRID_DICT, 'label') == label
        grp.erase!
      end
      model.commit_operation
      @gridlines.delete(label)
      true
    end

    def self.clear_all
      model = Sketchup.active_model
      return unless model
      model.start_operation('Clear All Gridlines', true)
      model.active_entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        next unless grp.get_attribute(GRID_DICT, 'label')
        grp.erase!
      end
      model.commit_operation
      @gridlines.clear
    end

    def self.list_gridlines
      model = Sketchup.active_model
      return [] unless model

      grids = []
      seen_labels = {}

      # Pass 1: Grid plane groups (from GridlineSystem)
      model.active_entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        label = grp.get_attribute(GRID_DICT, 'label')
        next unless label
        grids << {
          label: label,
          axis: grp.get_attribute(GRID_DICT, 'axis'),
          position: grp.get_attribute(GRID_DICT, 'position').to_f,
          position_ft: (grp.get_attribute(GRID_DICT, 'position').to_f / 12.0).round(2),
          eid: grp.entityID,
          visible: grp.visible?
        }
        seen_labels[label] = true
      end

      # Pass 2: Annotation tag groups marked as GRID (circle tags)
      model.active_entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        next unless grp.get_attribute('TakeoffMeasurement', 'type') == 'GRID'
        label = grp.get_attribute('TakeoffMeasurement', 'custom_label')
        next unless label
        next if seen_labels[label]  # Already have the plane entry for this grid
        # Tag without a plane — still list it
        require 'json'
        pt_json = grp.get_attribute('TakeoffMeasurement', 'point')
        pt = pt_json ? (JSON.parse(pt_json) rescue nil) : nil
        axis_lock = grp.get_attribute('TakeoffMeasurement', 'axis_lock').to_s
        axis = axis_lock == 'red' ? 'x' : 'y'
        pos = pt ? (axis == 'x' ? pt[0] : pt[1]) : 0
        grids << {
          label: label,
          axis: axis,
          position: pos.to_f,
          position_ft: (pos.to_f / 12.0).round(2),
          eid: grp.entityID,
          visible: grp.visible?
        }
        seen_labels[label] = true
      end

      grids.sort_by { |g| [g[:axis], g[:position]] }
    end

    def self.toggle_gridline(eid)
      grp = TakeoffTool.find_entity(eid.to_i)
      return unless grp && grp.valid?
      grp.visible = !grp.visible?
    end

    def self.toggle_all
      model = Sketchup.active_model
      return unless model
      grids = model.active_entities.grep(Sketchup::Group).select do |g|
        g.valid? && (g.get_attribute(GRID_DICT, 'label') || g.get_attribute('TakeoffMeasurement', 'type') == 'GRID')
      end
      any_vis = grids.any?(&:visible?)
      grids.each { |g| g.visible = !any_vis }
    end

    def self.grid_plane(label)
      info = @gridlines[label]
      return nil unless info
      if info[:axis] == :x
        { point: Geom::Point3d.new(info[:position], 0, 0), normal: Geom::Vector3d.new(1, 0, 0) }
      else
        { point: Geom::Point3d.new(0, info[:position], 0), normal: Geom::Vector3d.new(0, 1, 0) }
      end
    end
  end
end
