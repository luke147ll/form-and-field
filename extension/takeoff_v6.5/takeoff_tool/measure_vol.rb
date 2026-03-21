module TakeoffTool
  unless defined?(VOL_DEFAULT_COLOR)
  VOL_DEFAULT_COLOR = [203, 166, 247, 153]  # Mauve, semi-transparent
  end

  # ═══════════════════════════════════════════════════════════
  #  MeasureVolTool — click solid components/groups to accumulate
  #  volume in cubic yards. One-click per object, keeps adding
  #  to the same measurement group (like SF/LF face tools).
  # ═══════════════════════════════════════════════════════════

  class MeasureVolTool
    BOX_EXPAND = 0.75  # inches — expand box outward to avoid z-fighting

    def initialize(category, opts = {})
      @category = category
      @group_eid = opts[:group_eid]
      @label = opts[:label] || category
      @color_rgb = opts[:color]         # [r,g,b] or nil for default mauve
      @part_link_id = opts[:part_link_id]
      @hover_entity = nil
      @hover_volume_cy = 0.0
      @measurement_group = nil
      @total_cy = 0.0
      @object_count = 0
      @measured_eids = {}  # track which entities are already measured
    end

    def activate
      find_or_create_group
      rebuild_measured_eids
      recompute_totals
      display = @label != @category ? "#{@category} / #{@label}" : @category
      Sketchup.status_text = "Measure VOL [#{display}]: Click solid objects to measure volume. Total = #{'%.2f' % @total_cy} CY (#{@object_count} objects). Escape to finish."
    end

    def deactivate(view)
      # Link measurement group to derived part if this was a tool measurement
      if @part_link_id && @measurement_group && @measurement_group.valid?
        begin
          require 'json'
          m = Sketchup.active_model
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          if parts[@part_link_id]
            parts[@part_link_id]['sourceEid'] = @measurement_group.entityID
            m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
          end
        rescue => e
          puts "Takeoff: VOL part link error: #{e.message}"
        end
      end
      Dashboard.invalidate_measurement_cache rescue nil
      Dashboard.send_measurement_data rescue nil
      Dashboard.send_live_data rescue nil
      MeasurementsPanel.send_data rescue nil
      view.invalidate
    end

    def resume(view)
      recompute_totals
      display = @label != @category ? "#{@category} / #{@label}" : @category
      Sketchup.status_text = "Measure VOL [#{display}]: #{'%.2f' % @total_cy} CY (#{@object_count} objects). Click to add more. Escape to finish."
      view.invalidate
    end

    # ─── Mouse ───

    def onMouseMove(flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)

      entity = nil
      ph.count.times do |i|
        leaf = ph.leaf_at(i)
        path = ph.path_at(i)
        # Skip entities inside our own measurement group
        next if path && path.any? { |e| e == @measurement_group }

        # Walk path to find a ComponentInstance or Group with volume
        if path
          path.reverse_each do |pe|
            if pe.is_a?(Sketchup::ComponentInstance) || pe.is_a?(Sketchup::Group)
              entity = pe
              break
            end
          end
        end
        break if entity
      end

      if entity && !entity.equal?(@hover_entity)
        @hover_entity = entity
        is_manifold = false
        begin
          is_manifold = entity.respond_to?(:manifold?) && entity.manifold?
        rescue; end
        vol_cy = compute_volume_cy(entity)
        @hover_volume_cy = vol_cy
        already = @measured_eids[entity.entityID]
        prefix = already ? "\u2713 Already measured — " : ""
        method = is_manifold ? "solid" : "mesh"
        view.tooltip = "#{prefix}#{'%.3f' % vol_cy} CY (#{'%.1f' % (vol_cy * 27)} CF) [#{method}]"
        view.invalidate
      elsif !entity && @hover_entity
        @hover_entity = nil
        @hover_volume_cy = 0.0
        view.invalidate
      end
    end

    def onLButtonDown(flags, x, y, view)
      return unless @hover_entity && @hover_entity.valid?

      # Skip already-measured entities
      if @measured_eids[@hover_entity.entityID]
        Sketchup.status_text = "Already measured — click a different object."
        return
      end

      model = Sketchup.active_model
      model.start_operation('Add Volume Object', false)

      begin
        find_or_create_group unless @measurement_group && @measurement_group.valid?

        entity = @hover_entity
        eid = entity.entityID

        # Compute volume — manifold first, then mesh fallback
        vol_in3 = 0.0
        is_solid = false
        begin
          if entity.respond_to?(:manifold?) && entity.manifold?
            is_solid = true
            vol_in3 = entity.volume.to_f
          end
        rescue; end

        if vol_in3 <= 0
          vol_in3 = mesh_volume_in3(entity)
        end

        vol_cy = vol_in3 / 46656.0  # in³ → yd³

        # ── Create bounding-box shell artifact ──
        # The marker sub-group holds 6 semi-transparent faces that wrap
        # the source entity, making it obvious which objects are measured.
        bb = entity.bounds
        e = BOX_EXPAND  # expand slightly to prevent z-fighting

        # 8 corners of the expanded bounding box (world space)
        c = [
          Geom::Point3d.new(bb.min.x - e, bb.min.y - e, bb.min.z - e),  # 0: min corner
          Geom::Point3d.new(bb.max.x + e, bb.min.y - e, bb.min.z - e),  # 1
          Geom::Point3d.new(bb.max.x + e, bb.max.y + e, bb.min.z - e),  # 2
          Geom::Point3d.new(bb.min.x - e, bb.max.y + e, bb.min.z - e),  # 3
          Geom::Point3d.new(bb.min.x - e, bb.min.y - e, bb.max.z + e),  # 4
          Geom::Point3d.new(bb.max.x + e, bb.min.y - e, bb.max.z + e),  # 5
          Geom::Point3d.new(bb.max.x + e, bb.max.y + e, bb.max.z + e),  # 6
          Geom::Point3d.new(bb.min.x - e, bb.max.y + e, bb.max.z + e),  # 7
        ]

        marker = @measurement_group.entities.add_group
        ents = marker.entities
        mat = get_vol_material(model)

        # 6 faces of the box (wound so normals point outward)
        faces = []
        faces << ents.add_face(c[0], c[1], c[2], c[3])  # bottom (Z min)
        faces << ents.add_face(c[4], c[7], c[6], c[5])  # top    (Z max)
        faces << ents.add_face(c[0], c[4], c[5], c[1])  # front  (Y min)
        faces << ents.add_face(c[2], c[6], c[7], c[3])  # back   (Y max)
        faces << ents.add_face(c[0], c[3], c[7], c[4])  # left   (X min)
        faces << ents.add_face(c[1], c[5], c[6], c[2])  # right  (X max)

        faces.each do |f|
          next unless f
          f.material = mat
          f.back_material = mat
        end

        # Store reference data on the marker
        marker.set_attribute('VOL_Marker', 'source_eid', eid)
        marker.set_attribute('VOL_Marker', 'volume_in3', vol_in3)
        marker.set_attribute('VOL_Marker', 'volume_cy', vol_cy.round(4))
        marker.set_attribute('VOL_Marker', 'is_solid', is_solid)
        marker.set_attribute('VOL_Marker', 'name', entity.respond_to?(:definition) ? entity.definition.name : entity.name)

        @measured_eids[eid] = true

        recompute_totals
        update_group_attributes
        model.commit_operation

        display = @label != @category ? "#{@category} / #{@label}" : @category
        Sketchup.status_text = "Measure VOL [#{display}]: #{'%.2f' % @total_cy} CY (#{@object_count} objects). Click to add more. Escape to finish."
      rescue => e
        model.abort_operation
        puts "MeasureVol error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      end

      view.invalidate
    end

    def onKeyDown(key, repeat, flags, view)
      if key == 27
        Sketchup.active_model.select_tool(nil)
      end
      false
    end

    def onCancel(reason, view)
      Sketchup.active_model.select_tool(nil)
    end

    def draw(view)
      return unless @hover_entity && @hover_entity.valid?
      begin
        # Highlight the hovered entity's bounding box
        bb = @hover_entity.bounds
        r, g, b = active_color_rgb

        # Draw bounding box edges
        pts = [
          bb.corner(0), bb.corner(1), bb.corner(3), bb.corner(2), bb.corner(0),
          bb.corner(4), bb.corner(5), bb.corner(7), bb.corner(6), bb.corner(4)
        ]
        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(r, g, b, 200)
        view.draw(GL_LINE_STRIP, pts)

        # Connect top and bottom
        view.draw(GL_LINES, [
          bb.corner(1), bb.corner(5),
          bb.corner(3), bb.corner(7),
          bb.corner(2), bb.corner(6)
        ])
      rescue
      end
    end

    def getExtents
      bb = Geom::BoundingBox.new
      if @hover_entity && @hover_entity.valid?
        bb.add(@hover_entity.bounds)
      end
      bb
    end

    private

    def compute_volume_cy(entity)
      vol_in3 = 0.0
      begin
        if entity.respond_to?(:manifold?) && entity.manifold?
          vol_in3 = entity.volume.to_f
        end
      rescue; end

      # Fallback: compute from face mesh using signed tetrahedra
      # Works for any closed or near-closed shape (L-shapes, curves, etc.)
      if vol_in3 <= 0
        vol_in3 = mesh_volume_in3(entity)
      end

      vol_in3 / 46656.0  # in³ → yd³
    end

    # Compute volume from triangulated face geometry using the divergence theorem.
    # Each triangle contributes a signed tetrahedron volume relative to the origin.
    # Sum of all = enclosed volume for any closed mesh. Works for L-shapes, T-shapes, etc.
    def mesh_volume_in3(entity)
      defn = entity.respond_to?(:definition) ? entity.definition : nil
      return bb_volume_in3(entity) unless defn

      xform = entity.transformation
      total = 0.0

      defn.entities.grep(Sketchup::Face).each do |face|
        mesh = face.mesh(0)
        (1..mesh.count_polygons).each do |pi|
          tri = mesh.polygon_points_at(pi)
          next unless tri && tri.length >= 3
          p0 = xform * tri[0]
          p1 = xform * tri[1]
          p2 = xform * tri[2]
          # Signed volume of tetrahedron formed with origin
          total += (
            p0.x * (p1.y * p2.z - p2.y * p1.z) -
            p1.x * (p0.y * p2.z - p2.y * p0.z) +
            p2.x * (p0.y * p1.z - p1.y * p0.z)
          )
        end
      end

      vol = (total / 6.0).abs
      # Sanity check: if mesh volume is unreasonably small, fall back to bounding box
      vol > 0.01 ? vol : bb_volume_in3(entity)
    end

    def bb_volume_in3(entity)
      bb = entity.bounds
      bb.width.to_f * bb.height.to_f * bb.depth.to_f
    end

    def bb_volume_cy(entity)
      bb_volume_in3(entity) / 46656.0
    end

    def active_color_rgb
      @color_rgb || begin
        if @measurement_group && @measurement_group.valid?
          require 'json'
          rgba_json = @measurement_group.get_attribute('TakeoffMeasurement', 'color_rgba')
          arr = rgba_json ? (JSON.parse(rgba_json) rescue nil) : nil
          arr && arr.length >= 3 ? arr[0..2] : [203, 166, 247]
        else
          [203, 166, 247]
        end
      end
    end

    def get_vol_material(model)
      r, g, b = active_color_rgb
      eid = @measurement_group ? @measurement_group.entityID : 0
      mat_name = "FF_VOL_#{eid}"
      mat = model.materials[mat_name] || model.materials.add(mat_name)
      mat.color = Sketchup::Color.new(r, g, b)
      mat.alpha = 0.4
      mat
    end

    def rebuild_measured_eids
      @measured_eids = {}
      return unless @measurement_group && @measurement_group.valid?
      @measurement_group.entities.grep(Sketchup::Group).each do |g|
        next unless g.valid?
        src = g.get_attribute('VOL_Marker', 'source_eid')
        @measured_eids[src.to_i] = true if src
      end
    end

    def find_or_create_group
      m = Sketchup.active_model
      return unless m

      # Target specific group by eid if provided
      if @group_eid
        grp = TakeoffTool.find_entity(@group_eid)
        if grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'VOL'
          @measurement_group = grp
          @label = grp.get_attribute('TakeoffMeasurement', 'label') || @label
          return
        end
      end

      # Create new group
      require 'json'
      tag_name = 'TO_Measurements'
      tag = m.layers[tag_name] || m.layers.add(tag_name)
      r, g, b = @color_rgb || [203, 166, 247]

      @measurement_group = m.active_entities.add_group
      @measurement_group.entities.add_cpoint(ORIGIN)  # prevent auto-delete
      @measurement_group.layer = tag
      @measurement_group.name = "TO_VOL: #{@label} — 0.00 CY"
      @measurement_group.set_attribute('TakeoffMeasurement', 'type', 'VOL')
      @measurement_group.set_attribute('TakeoffMeasurement', 'category', @category)
      @measurement_group.set_attribute('TakeoffMeasurement', 'label', @label)
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_cy', 0.0)
      @measurement_group.set_attribute('TakeoffMeasurement', 'object_count', 0)
      @measurement_group.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
      @measurement_group.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      @measurement_group.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([r, g, b, 153]))
      @measurement_group.set_attribute('TakeoffMeasurement', 'material_name', "FF_VOL_#{@measurement_group.entityID}")

      if @part_link_id
        @measurement_group.set_attribute('TakeoffMeasurement', 'part_link', @part_link_id)
      end

      TakeoffTool.entity_registry[@measurement_group.entityID] = @measurement_group
      TakeoffTool.invalidate_entity_cache
    end

    def recompute_totals
      if @measurement_group && @measurement_group.valid?
        markers = @measurement_group.entities.grep(Sketchup::Group).select { |g|
          g.valid? && g.get_attribute('VOL_Marker', 'volume_cy')
        }
        @object_count = markers.length
        @total_cy = markers.sum { |g| (g.get_attribute('VOL_Marker', 'volume_cy') || 0).to_f }.round(4)
      else
        @object_count = 0
        @total_cy = 0.0
      end
    end

    def update_group_attributes
      return unless @measurement_group && @measurement_group.valid?
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_cy', @total_cy)
      @measurement_group.set_attribute('TakeoffMeasurement', 'object_count', @object_count)
      @measurement_group.name = "TO_VOL: #{@label} — #{'%.2f' % @total_cy} CY"
      @measurement_group.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
    end
  end

  # ═══════════════════════════════════════════════════════════
  #  RemoveVolObjectTool — click marker groups inside a VOL
  #  measurement to remove them. Totals update automatically.
  # ═══════════════════════════════════════════════════════════

  class RemoveVolObjectTool
    def initialize(group_eid)
      @group_eid = group_eid.to_i
      @measurement_group = nil
      @hover_marker = nil
      @label = nil
    end

    def activate
      m = Sketchup.active_model
      return Sketchup.active_model.select_tool(nil) unless m

      grp = TakeoffTool.find_entity(@group_eid)
      if grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'VOL'
        @measurement_group = grp
        @label = grp.get_attribute('TakeoffMeasurement', 'label') || 'Volume'
      end

      unless @measurement_group
        puts "RemoveVolObject: No VOL measurement group found for eid=#{@group_eid}"
        Sketchup.active_model.select_tool(nil)
        return
      end

      @measurement_group.visible = true
      markers = @measurement_group.entities.grep(Sketchup::Group).select { |g|
        g.valid? && g.get_attribute('VOL_Marker', 'volume_cy')
      }
      Sketchup.status_text = "Remove VOL [#{@label}]: Click objects to remove (#{markers.length} objects). Escape to finish."
    end

    def deactivate(view)
      Dashboard.invalidate_measurement_cache rescue nil
      Dashboard.send_measurement_data rescue nil
      Dashboard.send_live_data rescue nil
      MeasurementsPanel.send_data rescue nil
      view.invalidate
    end

    def resume(view)
      if @measurement_group && @measurement_group.valid?
        markers = @measurement_group.entities.grep(Sketchup::Group).select { |g|
          g.valid? && g.get_attribute('VOL_Marker', 'volume_cy')
        }
        Sketchup.status_text = "Remove VOL [#{@label}]: Click objects to remove (#{markers.length} objects). Escape to finish."
      end
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      @hover_marker = nil
      return unless @measurement_group && @measurement_group.valid?

      ph = view.pick_helper
      ph.do_pick(x, y)

      # Find a marker group by looking for our measurement group in the pick path
      ph.count.times do |i|
        path = ph.path_at(i)
        next unless path
        # Check if path passes through our measurement group
        mg_idx = path.index(@measurement_group)
        next unless mg_idx
        # The marker sub-group should be the next element after measurement group
        marker = path[mg_idx + 1]
        next unless marker.is_a?(Sketchup::Group) && marker.valid?
        next unless marker.get_attribute('VOL_Marker', 'volume_cy')
        @hover_marker = marker
        name = marker.get_attribute('VOL_Marker', 'name') || 'Object'
        vol = (marker.get_attribute('VOL_Marker', 'volume_cy') || 0).to_f
        view.tooltip = "Click to remove: #{name} (#{'%.3f' % vol} CY)"
        break
      end

      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return unless @hover_marker && @hover_marker.valid?
      return unless @measurement_group && @measurement_group.valid?

      model = Sketchup.active_model
      model.start_operation('Remove Volume Object', false)
      begin
        @hover_marker.erase!
        @hover_marker = nil

        # Update totals
        markers = @measurement_group.entities.grep(Sketchup::Group).select { |g|
          g.valid? && g.get_attribute('VOL_Marker', 'volume_cy')
        }
        total_cy = markers.sum { |g| (g.get_attribute('VOL_Marker', 'volume_cy') || 0).to_f }.round(4)
        @measurement_group.set_attribute('TakeoffMeasurement', 'total_cy', total_cy)
        @measurement_group.set_attribute('TakeoffMeasurement', 'object_count', markers.length)
        @measurement_group.name = "TO_VOL: #{@label} — #{'%.2f' % total_cy} CY"
        model.commit_operation

        Sketchup.status_text = "Remove VOL [#{@label}]: #{'%.2f' % total_cy} CY (#{markers.length} objects). Click to remove more. Escape to finish."
      rescue => e
        model.abort_operation
        puts "RemoveVolObject error: #{e.message}"
      end

      view.invalidate
    end

    def onKeyDown(key, repeat, flags, view)
      if key == 27
        Sketchup.active_model.select_tool(nil)
      end
      false
    end

    def onCancel(reason, view)
      Sketchup.active_model.select_tool(nil)
    end

    def draw(view)
      return unless @hover_marker && @hover_marker.valid?
      begin
        # Highlight the marker's bounding box in red
        bb = @hover_marker.bounds
        pts = [
          bb.corner(0), bb.corner(1), bb.corner(3), bb.corner(2), bb.corner(0),
          bb.corner(4), bb.corner(5), bb.corner(7), bb.corner(6), bb.corner(4)
        ]
        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(243, 139, 168, 220)
        view.draw(GL_LINE_STRIP, pts)
        view.draw(GL_LINES, [
          bb.corner(1), bb.corner(5),
          bb.corner(3), bb.corner(7),
          bb.corner(2), bb.corner(6)
        ])
      rescue
      end
    end

    def getExtents
      Geom::BoundingBox.new
    end
  end

  # ─── Module entry points ───

  def self.activate_vol_tool
    Sketchup.active_model.select_tool(MeasureVolTool.new('Custom'))
  end

  def self.activate_vol_tool_for_category(cat)
    Sketchup.active_model.select_tool(MeasureVolTool.new(cat))
  end

  def self.activate_vol_tool_for_group(group_eid, category)
    Sketchup.active_model.select_tool(MeasureVolTool.new(category, group_eid: group_eid.to_i))
  end

  def self.activate_vol_tool_new(category, label, color_rgb)
    Sketchup.active_model.select_tool(MeasureVolTool.new(category, label: label, color: color_rgb))
  end

  def self.activate_remove_vol_tool(group_eid)
    Sketchup.active_model.select_tool(RemoveVolObjectTool.new(group_eid))
  end

  def self.update_vol_label(group_eid, new_label)
    grp = find_entity(group_eid.to_i)
    return unless grp && grp.valid?
    m = Sketchup.active_model
    m.start_operation('Rename VOL Measurement', true)
    grp.set_attribute('TakeoffMeasurement', 'label', new_label)
    total = grp.get_attribute('TakeoffMeasurement', 'total_cy') || 0
    grp.name = "TO_VOL: #{new_label} — #{'%.2f' % total} CY"
    m.commit_operation
  end

  def self.update_vol_color(group_eid, color_rgb)
    grp = find_entity(group_eid.to_i)
    return unless grp && grp.valid?
    m = Sketchup.active_model
    require 'json'
    m.start_operation('Change VOL Color', true)
    grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([color_rgb[0], color_rgb[1], color_rgb[2], 153]))
    # Repaint all marker faces
    r, g, b = color_rgb
    mat_name = "FF_VOL_#{grp.entityID}"
    mat = m.materials[mat_name] || m.materials.add(mat_name)
    mat.color = Sketchup::Color.new(r, g, b)
    mat.alpha = 0.4
    grp.entities.grep(Sketchup::Group).each do |marker|
      next unless marker.valid?
      marker.entities.grep(Sketchup::Face).each do |face|
        face.material = mat
        face.back_material = mat
      end
    end
    m.commit_operation
  end
end
