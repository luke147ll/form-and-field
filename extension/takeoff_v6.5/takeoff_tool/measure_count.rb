module TakeoffTool
  unless defined?(COUNT_DEFAULT_COLOR)
    COUNT_DEFAULT_COLOR = [249, 226, 175, 180]  # Yellow, semi-transparent
  end

  # ═══════════════════════════════════════════════════════════
  #  MeasureCountTool — click anywhere to place count markers.
  #  Each click = +1 count.  The measurement card shows total EA.
  #  A small diamond marker is left at each click point.
  # ═══════════════════════════════════════════════════════════

  class MeasureCountTool
    MARKER_SIZE = 3.0 unless defined?(MARKER_SIZE)  # inches — half-width of the diamond marker

    def initialize(category, opts = {})
      @category = category
      @group_eid = opts[:group_eid]
      @label = opts[:label] || category
      @color_rgb = opts[:color]
      @part_link_id = opts[:part_link_id]
      @hover_pt = nil
      @hover_normal = nil
      @measurement_group = nil
      @total_count = 0
      @panel = nil
    end

    def activate
      find_or_create_group
      recompute_totals
      update_panel_total
      display = @label != @category ? "#{@category} / #{@label}" : @category
      Sketchup.status_text = "Count [#{display}]: Click to place markers. Total = #{@total_count} EA. Escape to finish."
      open_panel
    end

    def deactivate(view)
      close_panel
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
          puts "Takeoff: COUNT part link error: #{e.message}"
        end
      end
      Dashboard.invalidate_measurement_cache rescue nil
      Dashboard.send_measurement_data rescue nil
      Dashboard.send_live_data rescue nil
      view.invalidate
    end

    def resume(view)
      recompute_totals
      update_panel_total
      display = @label != @category ? "#{@category} / #{@label}" : @category
      Sketchup.status_text = "Count [#{display}]: #{@total_count} EA. Click to add more. Escape to finish."
      view.invalidate
    end

    # ─── Panel ───

    def open_panel
      @panel = UI::HtmlDialog.new(
        dialog_title: "Count Tool",
        width: 240, height: 220,
        left: 80, top: 200,
        style: UI::HtmlDialog::STYLE_UTILITY,
        resizable: false
      )
      tool_ref = self
      @panel.add_action_callback('pickColor') do |_ctx, json_str|
        begin
          require 'json'
          rgb = JSON.parse(json_str.to_s)
          if rgb.is_a?(Array) && rgb.length >= 3
            tool_ref.instance_variable_set(:@color_rgb, rgb)
            tool_ref.send(:apply_color, rgb)
          end
        rescue => e
          puts "Count pickColor error: #{e.message}"
        end
      end
      @panel.set_on_closed { @panel = nil }
      @panel.set_html(color_panel_html)
      @panel.show
    end

    def close_panel
      return unless @panel
      p = @panel
      @panel = nil
      begin; p.set_on_closed {}; p.close; rescue; end
    end

    def apply_color(rgb)
      return unless @measurement_group && @measurement_group.valid?
      require 'json'
      m = Sketchup.active_model
      m.start_operation('Change Count Color', true)
      @measurement_group.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate(rgb + [180]))
      mat = get_count_material(m)
      @measurement_group.entities.grep(Sketchup::Face).each do |face|
        face.material = mat
        face.back_material = mat
      end
      m.commit_operation
      Sketchup.active_model.active_view.invalidate
    end

    def update_panel_total
      return unless @panel
      @panel.execute_script("document.getElementById('total').textContent='#{@total_count} EA'") rescue nil
    end

    def color_panel_html
      r, g, b = active_color_rgb
      swatches = SF_COLOR_PALETTE.map { |c|
        cr, cg, cb = c[:rgb]
        sel = (cr == r && cg == g && cb == b) ? ' sw-sel' : ''
        "<span class=\"sw#{sel}\" style=\"background:rgb(#{cr},#{cg},#{cb})\" onclick=\"pickColor(#{cr},#{cg},#{cb})\"></span>"
      }.join
      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font:13px/1.4 'Segoe UI',system-ui,sans-serif;background:#1e1e2e;color:#cdd6f4;padding:14px}
        .hdr{font-size:11px;font-weight:700;color:#cba6f7;text-transform:uppercase;letter-spacing:1px;text-align:center;margin-bottom:6px}
        .cat{font-size:11px;color:#a6adc8;text-align:center;margin-bottom:10px}
        .cat b{color:#f9e2af}
        label{display:block;color:#a6adc8;font-size:11px;margin-bottom:4px;font-weight:600;text-transform:uppercase;letter-spacing:0.5px}
        .swatches{display:flex;flex-wrap:wrap;gap:5px;margin-top:4px}
        .sw{width:18px;height:18px;border-radius:50%;cursor:pointer;border:2px solid transparent;transition:border-color .15s}
        .sw:hover{border-color:#cdd6f4}
        .sw-sel{border-color:#fff;box-shadow:0 0 0 1px #1e1e2e,0 0 4px rgba(255,255,255,.4)}
        .total{font-size:16px;font-weight:700;color:#a6e3a1;text-align:center;margin-top:12px}
        </style></head><body>
        <div class="hdr">Count Tool</div>
        <div class="cat">Category: <b>#{@category}</b></div>
        <label>Color</label>
        <div class="swatches">#{swatches}</div>
        <div class="total" id="total">#{@total_count} EA</div>
        <script>
        function pickColor(r,g,b){
          var dots=document.querySelectorAll('.sw');
          dots.forEach(function(d){d.classList.remove('sw-sel');});
          event.target.classList.add('sw-sel');
          sketchup.pickColor(JSON.stringify([r,g,b]));
        }
        </script>
        </body></html>
      HTML
    end

    # ─── Mouse ───

    def onMouseMove(flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)

      # Try to pick a face to place marker on its surface
      best = ph.best_picked
      if best.is_a?(Sketchup::Face)
        ip = view.inputpoint(x, y)
        @hover_pt = ip.position
        @hover_normal = best.normal
      else
        ip = view.inputpoint(x, y)
        @hover_pt = ip.position
        @hover_normal = Z_AXIS
      end

      view.tooltip = "Click to place count marker"
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return unless @hover_pt

      model = Sketchup.active_model
      model.start_operation('Add Count Marker', false)

      begin
        find_or_create_group unless @measurement_group && @measurement_group.valid?

        pt = @hover_pt
        normal = @hover_normal || Z_AXIS

        # Create a small diamond marker at the click point
        marker = @measurement_group.entities.add_group
        ents = marker.entities
        mat = get_count_material(model)

        s = MARKER_SIZE
        # Build a flat diamond in the XY plane, then orient to face normal
        pts_local = [
          Geom::Point3d.new(0, s, 0),
          Geom::Point3d.new(s, 0, 0),
          Geom::Point3d.new(0, -s, 0),
          Geom::Point3d.new(-s, 0, 0)
        ]

        face = ents.add_face(pts_local)
        if face
          face.material = mat
          face.back_material = mat
        end

        # Orient marker: rotate from Z_AXIS to surface normal, then translate
        # Offset slightly along normal to avoid z-fighting
        offset_pt = Geom::Point3d.new(
          pt.x + normal.x * 0.25,
          pt.y + normal.y * 0.25,
          pt.z + normal.z * 0.25
        )

        if normal.parallel?(Z_AXIS)
          xform = Geom::Transformation.new(offset_pt)
          # Flip if normal points down
          if normal.z < 0
            xform = xform * Geom::Transformation.rotation(ORIGIN, X_AXIS, Math::PI)
          end
        else
          angle = Z_AXIS.angle_between(normal)
          axis = Z_AXIS * normal
          if axis.length > 0.001
            rot = Geom::Transformation.rotation(ORIGIN, axis, angle)
            xform = Geom::Transformation.new(offset_pt) * rot
          else
            xform = Geom::Transformation.new(offset_pt)
          end
        end

        marker.transformation = xform

        marker.set_attribute('COUNT_Marker', 'placed', true)
        marker.set_attribute('COUNT_Marker', 'timestamp', Time.now.to_s)

        recompute_totals
        update_panel_total
        update_group_attributes
        model.commit_operation

        display = @label != @category ? "#{@category} / #{@label}" : @category
        Sketchup.status_text = "Count [#{display}]: #{@total_count} EA. Click to add more. Escape to finish."
      rescue => e
        model.abort_operation
        puts "MeasureCount error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
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
      return unless @hover_pt
      begin
        r, g, b = active_color_rgb

        # Draw a crosshair at hover point
        s = view.pixels_to_model(8, @hover_pt)
        normal = @hover_normal || Z_AXIS

        # Pick two perpendicular axes in the plane
        if normal.parallel?(Z_AXIS)
          ax1 = X_AXIS
          ax2 = Y_AXIS
        else
          ax1 = normal * Z_AXIS
          ax1.normalize! if ax1.length > 0.001
          ax2 = normal * ax1
          ax2.normalize! if ax2.length > 0.001
        end

        p1 = Geom::Point3d.new(@hover_pt.x + ax1.x*s, @hover_pt.y + ax1.y*s, @hover_pt.z + ax1.z*s)
        p2 = Geom::Point3d.new(@hover_pt.x - ax1.x*s, @hover_pt.y - ax1.y*s, @hover_pt.z - ax1.z*s)
        p3 = Geom::Point3d.new(@hover_pt.x + ax2.x*s, @hover_pt.y + ax2.y*s, @hover_pt.z + ax2.z*s)
        p4 = Geom::Point3d.new(@hover_pt.x - ax2.x*s, @hover_pt.y - ax2.y*s, @hover_pt.z - ax2.z*s)

        # Diamond outline
        d = view.pixels_to_model(6, @hover_pt)
        dp = [
          Geom::Point3d.new(@hover_pt.x + ax1.x*d, @hover_pt.y + ax1.y*d, @hover_pt.z + ax1.z*d),
          Geom::Point3d.new(@hover_pt.x + ax2.x*d, @hover_pt.y + ax2.y*d, @hover_pt.z + ax2.z*d),
          Geom::Point3d.new(@hover_pt.x - ax1.x*d, @hover_pt.y - ax1.y*d, @hover_pt.z - ax1.z*d),
          Geom::Point3d.new(@hover_pt.x - ax2.x*d, @hover_pt.y - ax2.y*d, @hover_pt.z - ax2.z*d),
          Geom::Point3d.new(@hover_pt.x + ax1.x*d, @hover_pt.y + ax1.y*d, @hover_pt.z + ax1.z*d)
        ]

        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(r, g, b, 220)
        view.draw(GL_LINES, [p1, p2, p3, p4])
        view.draw(GL_LINE_STRIP, dp)
      rescue
      end
    end

    def getExtents
      bb = Geom::BoundingBox.new
      bb.add(@hover_pt) if @hover_pt
      bb
    end

    private

    def active_color_rgb
      @color_rgb || begin
        if @measurement_group && @measurement_group.valid?
          require 'json'
          rgba_json = @measurement_group.get_attribute('TakeoffMeasurement', 'color_rgba')
          arr = rgba_json ? (JSON.parse(rgba_json) rescue nil) : nil
          arr && arr.length >= 3 ? arr[0..2] : [249, 226, 175]
        else
          [249, 226, 175]
        end
      end
    end

    def get_count_material(model)
      r, g, b = active_color_rgb
      eid = @measurement_group ? @measurement_group.entityID : 0
      mat_name = "FF_COUNT_#{eid}"
      mat = model.materials[mat_name] || model.materials.add(mat_name)
      mat.color = Sketchup::Color.new(r, g, b)
      mat.alpha = 0.7
      mat
    end

    def find_or_create_group
      m = Sketchup.active_model
      return unless m

      if @group_eid
        grp = TakeoffTool.find_entity(@group_eid)
        if grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'COUNT'
          @measurement_group = grp
          @label = grp.get_attribute('TakeoffMeasurement', 'label') || @label
          return
        end
      end

      require 'json'
      tag_name = 'TO_Measurements'
      tag = m.layers[tag_name] || m.layers.add(tag_name)
      r, g, b = @color_rgb || [249, 226, 175]

      @measurement_group = m.active_entities.add_group
      @measurement_group.entities.add_cpoint(ORIGIN)
      @measurement_group.layer = tag
      @measurement_group.name = "TO_COUNT: #{@label} — 0 EA"
      @measurement_group.set_attribute('TakeoffMeasurement', 'type', 'COUNT')
      @measurement_group.set_attribute('TakeoffMeasurement', 'category', @category)
      @measurement_group.set_attribute('TakeoffMeasurement', 'label', @label)
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_count', 0)
      @measurement_group.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
      @measurement_group.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      @measurement_group.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([r, g, b, 180]))
      @measurement_group.set_attribute('TakeoffMeasurement', 'material_name', "FF_COUNT_#{@measurement_group.entityID}")

      if @part_link_id
        @measurement_group.set_attribute('TakeoffMeasurement', 'part_link', @part_link_id)
      end

      TakeoffTool.entity_registry[@measurement_group.entityID] = @measurement_group
      TakeoffTool.invalidate_entity_cache
    end

    def recompute_totals
      if @measurement_group && @measurement_group.valid?
        markers = @measurement_group.entities.grep(Sketchup::Group).select { |g|
          g.valid? && g.get_attribute('COUNT_Marker', 'placed')
        }
        @total_count = markers.length
      else
        @total_count = 0
      end
    end

    def update_group_attributes
      return unless @measurement_group && @measurement_group.valid?
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_count', @total_count)
      @measurement_group.name = "TO_COUNT: #{@label} — #{@total_count} EA"
      @measurement_group.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
    end
  end

  # ═══════════════════════════════════════════════════════════
  #  RemoveCountMarkerTool — click markers inside a COUNT group
  #  to delete them. Count updates automatically.
  # ═══════════════════════════════════════════════════════════

  class RemoveCountMarkerTool
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
      if grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'COUNT'
        @measurement_group = grp
        @label = grp.get_attribute('TakeoffMeasurement', 'label') || 'Count'
      end

      unless @measurement_group
        puts "RemoveCountMarker: No COUNT group found for eid=#{@group_eid}"
        Sketchup.active_model.select_tool(nil)
        return
      end

      @measurement_group.visible = true
      markers = @measurement_group.entities.grep(Sketchup::Group).select { |g|
        g.valid? && g.get_attribute('COUNT_Marker', 'placed')
      }
      Sketchup.status_text = "Remove Count [#{@label}]: Click markers to remove (#{markers.length} markers). Escape to finish."
    end

    def deactivate(view)
      Dashboard.invalidate_measurement_cache rescue nil
      Dashboard.send_measurement_data rescue nil
      Dashboard.send_live_data rescue nil
      view.invalidate
    end

    def resume(view)
      if @measurement_group && @measurement_group.valid?
        markers = @measurement_group.entities.grep(Sketchup::Group).select { |g|
          g.valid? && g.get_attribute('COUNT_Marker', 'placed')
        }
        Sketchup.status_text = "Remove Count [#{@label}]: Click markers to remove (#{markers.length} markers). Escape to finish."
      end
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      @hover_marker = nil
      return unless @measurement_group && @measurement_group.valid?

      ph = view.pick_helper
      ph.do_pick(x, y)

      ph.count.times do |i|
        path = ph.path_at(i)
        next unless path
        mg_idx = path.index(@measurement_group)
        next unless mg_idx
        marker = path[mg_idx + 1]
        next unless marker.is_a?(Sketchup::Group) && marker.valid?
        next unless marker.get_attribute('COUNT_Marker', 'placed')
        @hover_marker = marker
        view.tooltip = "Click to remove this marker"
        break
      end

      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return unless @hover_marker && @hover_marker.valid?
      return unless @measurement_group && @measurement_group.valid?

      model = Sketchup.active_model
      model.start_operation('Remove Count Marker', false)
      begin
        @hover_marker.erase!
        @hover_marker = nil

        markers = @measurement_group.entities.grep(Sketchup::Group).select { |g|
          g.valid? && g.get_attribute('COUNT_Marker', 'placed')
        }
        count = markers.length
        @measurement_group.set_attribute('TakeoffMeasurement', 'total_count', count)
        @measurement_group.name = "TO_COUNT: #{@label} — #{count} EA"
        model.commit_operation

        Sketchup.status_text = "Remove Count [#{@label}]: #{count} EA. Click to remove more. Escape to finish."
      rescue => e
        model.abort_operation
        puts "RemoveCountMarker error: #{e.message}"
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

  def self.activate_count_tool_for_category(cat)
    Sketchup.active_model.select_tool(MeasureCountTool.new(cat))
  end

  def self.activate_count_tool_for_group(group_eid, category)
    Sketchup.active_model.select_tool(MeasureCountTool.new(category, group_eid: group_eid.to_i))
  end

  def self.activate_count_tool_new(category, label, color_rgb)
    Sketchup.active_model.select_tool(MeasureCountTool.new(category, label: label, color: color_rgb))
  end

  def self.activate_remove_count_tool(group_eid)
    Sketchup.active_model.select_tool(RemoveCountMarkerTool.new(group_eid))
  end

  def self.update_count_label(group_eid, new_label)
    grp = find_entity(group_eid.to_i)
    return unless grp && grp.valid?
    m = Sketchup.active_model
    m.start_operation('Rename COUNT Measurement', true)
    grp.set_attribute('TakeoffMeasurement', 'label', new_label)
    total = grp.get_attribute('TakeoffMeasurement', 'total_count') || 0
    grp.name = "TO_COUNT: #{new_label} — #{total} EA"
    m.commit_operation
  end

  def self.update_count_color(group_eid, color_rgb)
    grp = find_entity(group_eid.to_i)
    return unless grp && grp.valid?
    m = Sketchup.active_model
    require 'json'
    m.start_operation('Change COUNT Color', true)
    grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([color_rgb[0], color_rgb[1], color_rgb[2], 180]))
    r, g, b = color_rgb
    mat_name = "FF_COUNT_#{grp.entityID}"
    mat = m.materials[mat_name] || m.materials.add(mat_name)
    mat.color = Sketchup::Color.new(r, g, b)
    mat.alpha = 0.7
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
