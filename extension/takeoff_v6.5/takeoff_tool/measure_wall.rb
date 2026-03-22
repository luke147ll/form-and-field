module TakeoffTool
  unless defined?(WALL_DEFAULT_COLOR)
    WALL_DEFAULT_COLOR = [116, 199, 236, 200]  # Sapphire, high-contrast against tan
  end

  # Nominal lumber lookup: actual inches -> nominal string
  WALL_NOMINAL = {
    1.5  => '2x',
    3.5  => '2x4',  # full match when both dims resolve
    5.5  => '2x6',
    7.25 => '2x8',
    9.25 => '2x10',
    11.25 => '2x12',
  }

  # Map wall thickness (smallest bbox dim in inches) to nominal frame size
  def self.thickness_to_nominal(inches)
    best = nil
    best_diff = 999
    {
      3.5 => '2x4', 5.5 => '2x6', 7.25 => '2x8',
      9.25 => '2x10', 11.25 => '2x12', 13.25 => '2x14'
    }.each do |actual, nom|
      diff = (inches - actual).abs
      if diff < best_diff
        best_diff = diff
        best = nom
      end
    end
    best_diff < 1.0 ? best : "#{inches.round(1)}\""
  end

  # ═══════════════════════════════════════════════════════════
  #  MeasureWallTool — click wall faces/components to measure
  #  wall segments. Auto-detects height, length, width from
  #  bounding box. Calculates studs + plates.
  # ═══════════════════════════════════════════════════════════

  class MeasureWallTool
    def initialize(opts = {})
      @category = opts[:category] || 'Wall Framing'
      @label = opts[:label] || @category
      @color_rgb = opts[:color]
      @oc_spacing = opts[:oc_spacing] || 16    # inches
      @plate_config = opts[:plates] || []       # [{material:'Plate', multiplier:1, stickLen:8}]
      @stud_length = opts[:stud_length]         # nil = auto from wall height
      @waste_pct = opts[:waste] || 5
      @hover_inst = nil
      @hover_faces = nil
      @hover_dims = nil
      @measurement_group = nil
      @wall_segments = []
    end

    def activate
      find_or_create_group
      recompute_totals
      Sketchup.status_text = "Wall Segment [#{@label}]: Click wall faces to measure. #{@wall_segments.length} segments. Escape to finish."
    end

    def deactivate(view)
      Dashboard.invalidate_measurement_cache rescue nil
      Dashboard.send_measurement_data rescue nil
      Dashboard.send_live_data rescue nil
      MeasurementsPanel.send_data rescue nil
      view.invalidate
    end

    def resume(view)
      recompute_totals
      Sketchup.status_text = "Wall Segment [#{@label}]: #{@wall_segments.length} segments, #{format_total_lf} LF total. Escape to finish."
      view.invalidate
    end

    # ─── Mouse ───

    def onMouseMove(flags, x, y, view)
      @hover_inst = nil
      @hover_faces = nil
      @hover_dims = nil

      ph = view.pick_helper
      ph.do_pick(x, y)

      # Walk pick results looking for a ComponentInstance or Group
      best = ph.best_picked
      inst = nil

      if best.is_a?(Sketchup::Face)
        # Walk up the pick path to find the containing instance
        path = ph.path_at(0)
        if path
          path.reverse_each do |pe|
            if pe.is_a?(Sketchup::ComponentInstance) || pe.is_a?(Sketchup::Group)
              inst = pe
              break
            end
          end
        end
      elsif best.is_a?(Sketchup::ComponentInstance) || best.is_a?(Sketchup::Group)
        inst = best
      end

      if inst && inst.valid?
        dims = analyze_wall(inst)
        if dims
          @hover_inst = inst
          @hover_dims = dims
          view.tooltip = "#{dims[:nominal]} wall: #{format_dim(dims[:length])} L x #{format_dim(dims[:height])} H\nClick to add segment"
        else
          view.tooltip = "Not a wall shape"
        end
      else
        view.tooltip = "Hover over a wall component"
      end

      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return unless @hover_inst && @hover_inst.valid? && @hover_dims

      model = Sketchup.active_model
      model.start_operation('Add Wall Segment', false)

      begin
        find_or_create_group unless @measurement_group && @measurement_group.valid?

        dims = @hover_dims
        inst = @hover_inst
        eid = inst.entityID

        # Check for duplicate — don't add same instance twice
        existing = @measurement_group.get_attribute('TakeoffMeasurement', 'wall_segments_json')
        if existing
          require 'json'
          segs = JSON.parse(existing) rescue []
          if segs.any? { |s| s['entityID'] == eid }
            model.abort_operation
            Sketchup.status_text = "Wall Segment [#{@label}]: Already added. #{@wall_segments.length} segments."
            return
          end
        end

        # Create a visual marker: a semi-transparent rectangle over the wall face
        create_wall_marker(dims, inst, view)

        # Store segment data — force all numerics to Float
        len = dims[:length].to_f
        ht = dims[:height].to_f
        thk = dims[:thickness].to_f
        seg = {
          'entityID' => eid,
          'length_in' => len,
          'height_in' => ht,
          'thickness_in' => thk,
          'nominal' => dims[:nominal],
          'length_ft' => (len / 12.0).round(2),
          'height_ft' => (ht / 12.0).round(2),
          'timestamp' => Time.now.to_s
        }

        @wall_segments << seg
        update_group_attributes
        model.commit_operation

        Sketchup.status_text = "Wall Segment [#{@label}]: #{@wall_segments.length} segments, #{format_total_lf} LF. Click more or Escape."
      rescue => e
        model.abort_operation
        puts "MeasureWall error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
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
      return unless @hover_inst && @hover_inst.valid? && @hover_dims
      begin
        # Highlight hovered instance bounding box
        bb = @hover_inst.bounds
        r, g, b = active_color_rgb
        pts = [
          bb.corner(0), bb.corner(1), bb.corner(3), bb.corner(2), bb.corner(0),
          bb.corner(4), bb.corner(5), bb.corner(7), bb.corner(6), bb.corner(4)
        ]
        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(r, g, b, 200)
        view.draw(GL_LINE_STRIP, pts)
        view.draw(GL_LINES, [
          bb.corner(1), bb.corner(5),
          bb.corner(3), bb.corner(7),
          bb.corner(2), bb.corner(6)
        ])

        # Draw dimension text at center
        center = bb.center
        dims = @hover_dims
        txt = "#{dims[:nominal]}  #{format_dim(dims[:length])} x #{format_dim(dims[:height])}"
        pt2d = view.screen_coords(center)
        view.draw_text(Geom::Point3d.new(pt2d.x + 15, pt2d.y - 10, 0), txt,
          size: 12, color: Sketchup::Color.new(r, g, b))
      rescue
      end
    end

    def getExtents
      bb = Geom::BoundingBox.new
      if @hover_inst && @hover_inst.valid?
        bb.add(@hover_inst.bounds.min, @hover_inst.bounds.max)
      end
      bb
    end

    private

    def analyze_wall(inst)
      # Use WORLD-SPACE bounding box — no local axis guessing.
      # Z extent = height, XY horizontal run = length, thinnest = thickness.
      bb = inst.bounds
      wx = (bb.max.x - bb.min.x).to_f  # world X extent
      wy = (bb.max.y - bb.min.y).to_f  # world Y extent
      wz = (bb.max.z - bb.min.z).to_f  # world Z extent

      # Height is always Z
      height = wz

      # Of X and Y: smaller is thickness, larger is length
      if wx >= wy
        length = wx
        thickness = wy
      else
        length = wy
        thickness = wx
      end

      # Wall heuristic checks
      return nil if thickness < 1.0 || thickness > 16.0   # must be wall-thickness range
      return nil if length < 12.0                          # at least 1 foot long
      return nil if height < 12.0                          # at least 1 foot tall

      nominal = TakeoffTool.thickness_to_nominal(thickness)

      len_ft = (length / 12.0).round(2)
      ht_ft = (height / 12.0).round(2)
      puts "WallAnalyze: #{nominal} | L=#{len_ft}' H=#{ht_ft}' T=#{thickness.round(2)}\" | world XYZ=[#{wx.round(1)}, #{wy.round(1)}, #{wz.round(1)}]"

      {
        length:    length,
        height:    height,
        thickness: thickness,
        nominal:   nominal
      }
    end

    def create_wall_marker(dims, inst, _view = nil)
      return unless @measurement_group && @measurement_group.valid?

      mat = get_wall_material(Sketchup.active_model)

      marker = @measurement_group.entities.add_group
      marker.set_attribute('WALL_Segment', 'placed', true)
      marker.set_attribute('WALL_Segment', 'entityID', inst.entityID)
      marker.set_attribute('WALL_Segment', 'length_in', dims[:length].to_f)
      marker.set_attribute('WALL_Segment', 'height_in', dims[:height].to_f)
      marker.set_attribute('WALL_Segment', 'thickness_in', dims[:thickness].to_f)
      marker.set_attribute('WALL_Segment', 'nominal', dims[:nominal])

      # 6-face bounding box shell (same approach as volume tool).
      # Uses world-space bbox — completely axis-agnostic.
      bb = inst.bounds
      e = 0.75  # expand outward to prevent z-fighting

      c = [
        Geom::Point3d.new(bb.min.x - e, bb.min.y - e, bb.min.z - e),  # 0
        Geom::Point3d.new(bb.max.x + e, bb.min.y - e, bb.min.z - e),  # 1
        Geom::Point3d.new(bb.max.x + e, bb.max.y + e, bb.min.z - e),  # 2
        Geom::Point3d.new(bb.min.x - e, bb.max.y + e, bb.min.z - e),  # 3
        Geom::Point3d.new(bb.min.x - e, bb.min.y - e, bb.max.z + e),  # 4
        Geom::Point3d.new(bb.max.x + e, bb.min.y - e, bb.max.z + e),  # 5
        Geom::Point3d.new(bb.max.x + e, bb.max.y + e, bb.max.z + e),  # 6
        Geom::Point3d.new(bb.min.x - e, bb.max.y + e, bb.max.z + e),  # 7
      ]

      ents = marker.entities
      faces = []
      faces << ents.add_face(c[0], c[1], c[2], c[3])  # bottom
      faces << ents.add_face(c[4], c[7], c[6], c[5])  # top
      faces << ents.add_face(c[0], c[4], c[5], c[1])  # front
      faces << ents.add_face(c[2], c[6], c[7], c[3])  # back
      faces << ents.add_face(c[0], c[3], c[7], c[4])  # left
      faces << ents.add_face(c[1], c[5], c[6], c[2])  # right

      faces.each do |f|
        next unless f
        f.material = mat
        f.back_material = mat
      end

      marker
    end

    def active_color_rgb
      @color_rgb || begin
        if @measurement_group && @measurement_group.valid?
          require 'json'
          rgba_json = @measurement_group.get_attribute('TakeoffMeasurement', 'color_rgba')
          arr = rgba_json ? (JSON.parse(rgba_json) rescue nil) : nil
          arr && arr.length >= 3 ? arr[0..2] : [116, 199, 236]
        else
          [116, 199, 236]
        end
      end
    end

    def get_wall_material(model)
      r, g, b = active_color_rgb
      eid = @measurement_group ? @measurement_group.entityID : 0
      mat_name = "FF_WALL_#{eid}"
      mat = model.materials[mat_name] || model.materials.add(mat_name)
      mat.color = Sketchup::Color.new(r, g, b)
      mat.alpha = 0.5
      mat
    end

    def find_or_create_group
      m = Sketchup.active_model
      return unless m

      # Look for existing wall measurement group with this label
      m.active_entities.each do |e|
        next unless e.is_a?(Sketchup::Group) && e.valid?
        next unless e.get_attribute('TakeoffMeasurement', 'type') == 'WALL'
        next unless e.get_attribute('TakeoffMeasurement', 'label') == @label
        @measurement_group = e
        load_segments_from_group
        return
      end

      require 'json'
      tag_name = 'TO_Measurements'
      tag = m.layers[tag_name] || m.layers.add(tag_name)
      r, g, b = @color_rgb || [116, 199, 236]

      @measurement_group = m.active_entities.add_group
      @measurement_group.entities.add_cpoint(ORIGIN)
      @measurement_group.layer = tag
      @measurement_group.name = "TO_WALL: #{@label} — 0 LF"
      @measurement_group.set_attribute('TakeoffMeasurement', 'type', 'WALL')
      @measurement_group.set_attribute('TakeoffMeasurement', 'category', @category)
      @measurement_group.set_attribute('TakeoffMeasurement', 'label', @label)
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_lf', 0)
      @measurement_group.set_attribute('TakeoffMeasurement', 'segment_count', 0)
      @measurement_group.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
      @measurement_group.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      @measurement_group.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([r, g, b, 160]))
      @measurement_group.set_attribute('TakeoffMeasurement', 'material_name', "FF_WALL_#{@measurement_group.entityID}")

      # Store framing config
      cfg = {
        'oc_spacing' => @oc_spacing,
        'plates' => @plate_config,
        'stud_length' => @stud_length,
        'waste_pct' => @waste_pct
      }
      @measurement_group.set_attribute('TakeoffMeasurement', 'wall_config', JSON.generate(cfg))
      @measurement_group.set_attribute('TakeoffMeasurement', 'wall_segments_json', '[]')

      TakeoffTool.entity_registry[@measurement_group.entityID] = @measurement_group
      TakeoffTool.invalidate_entity_cache
    end

    def load_segments_from_group
      require 'json'
      return unless @measurement_group && @measurement_group.valid?
      json = @measurement_group.get_attribute('TakeoffMeasurement', 'wall_segments_json')
      @wall_segments = json ? (JSON.parse(json) rescue []) : []

      # Load config
      cfg_json = @measurement_group.get_attribute('TakeoffMeasurement', 'wall_config')
      if cfg_json
        cfg = JSON.parse(cfg_json) rescue {}
        @oc_spacing = cfg['oc_spacing'] || @oc_spacing
        @plate_config = cfg['plates'] || @plate_config
        @stud_length = cfg['stud_length'] || @stud_length
        @waste_pct = cfg['waste_pct'] || @waste_pct
      end
    end

    def recompute_totals
      if @measurement_group && @measurement_group.valid?
        load_segments_from_group
      else
        @wall_segments = []
      end
    end

    def update_group_attributes
      return unless @measurement_group && @measurement_group.valid?
      require 'json'

      total_lf = @wall_segments.sum { |s| (s['length_ft'] || 0).to_f }
      @measurement_group.set_attribute('TakeoffMeasurement', 'wall_segments_json', JSON.generate(@wall_segments))
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_lf', total_lf.round(2))
      @measurement_group.set_attribute('TakeoffMeasurement', 'segment_count', @wall_segments.length)
      @measurement_group.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)

      # Compute framing from segments: LF * 12 / OC, waste covers end studs
      total_in = @wall_segments.sum { |s| (s['length_in'] || 0).to_f }
      total_studs = (total_in / @oc_spacing.to_f).ceil
      total_studs = (total_studs * (1 + @waste_pct / 100.0)).ceil

      @measurement_group.set_attribute('TakeoffMeasurement', 'total_studs', total_studs)
      @measurement_group.set_attribute('TakeoffMeasurement', 'oc_spacing', @oc_spacing)

      # Consolidate segments by nominal + similar height (within 6") for dashboard
      consolidated = {}
      @wall_segments.each do |s|
        h_ft = (s['height_ft'] || 0).to_f
        h_round = (h_ft * 2).round / 2.0  # round to nearest 0.5 ft
        key = "#{s['nominal']}_#{h_round}"
        if consolidated[key]
          consolidated[key][:count] += 1
          consolidated[key][:total_lf] += (s['length_ft'] || 0).to_f
        else
          consolidated[key] = {
            count: 1,
            nominal: s['nominal'],
            height_ft: h_ft,
            total_lf: (s['length_ft'] || 0).to_f
          }
        end
      end
      details = consolidated.values.map { |c|
        {
          'nominal' => c[:nominal],
          'h' => c[:height_ft].round(2),
          'lf' => c[:total_lf].round(2),
          'count' => c[:count]
        }
      }
      @measurement_group.set_attribute('TakeoffMeasurement', 'wall_details_json', JSON.generate(details))

      summary = @wall_segments.length > 0 ? "#{@wall_segments.length} seg, #{total_lf.round(1)} LF" : "0 LF"
      @measurement_group.name = "TO_WALL: #{@label} — #{summary}"
    end

    def format_total_lf
      @wall_segments.sum { |s| (s['length_ft'] || 0).to_f }.round(1).to_s
    end

    def format_dim(inches)
      inches = inches.to_f
      ft = (inches / 12).floor
      ins = (inches - ft * 12).round(1)
      if ft > 0 && ins > 0
        "#{ft}'-#{ins}\""
      elsif ft > 0
        "#{ft}'"
      else
        "#{ins}\""
      end
    end
  end

  # ═══════════════════════════════════════════════════════════
  #  RemoveWallSegmentTool — click wall markers to delete them
  # ═══════════════════════════════════════════════════════════

  class RemoveWallSegmentTool
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
      if grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'WALL'
        @measurement_group = grp
        @label = grp.get_attribute('TakeoffMeasurement', 'label') || 'Wall'
      end

      unless @measurement_group
        puts "RemoveWallSegment: No WALL group found for eid=#{@group_eid}"
        Sketchup.active_model.select_tool(nil)
        return
      end

      @measurement_group.visible = true
      segs = @measurement_group.entities.grep(Sketchup::Group).select { |g|
        g.valid? && g.get_attribute('WALL_Segment', 'placed')
      }
      Sketchup.status_text = "Remove Wall [#{@label}]: Click segments to remove (#{segs.length} segments). Escape to finish."
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
        segs = @measurement_group.entities.grep(Sketchup::Group).select { |g|
          g.valid? && g.get_attribute('WALL_Segment', 'placed')
        }
        Sketchup.status_text = "Remove Wall [#{@label}]: #{segs.length} segments. Escape to finish."
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
        next unless marker.get_attribute('WALL_Segment', 'placed')
        @hover_marker = marker
        nom = marker.get_attribute('WALL_Segment', 'nominal') || ''
        view.tooltip = "Click to remove #{nom} wall segment"
        break
      end

      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return unless @hover_marker && @hover_marker.valid?
      return unless @measurement_group && @measurement_group.valid?

      model = Sketchup.active_model
      model.start_operation('Remove Wall Segment', false)
      begin
        seg_eid = @hover_marker.get_attribute('WALL_Segment', 'entityID')
        @hover_marker.erase!
        @hover_marker = nil

        # Remove from segments JSON
        require 'json'
        json = @measurement_group.get_attribute('TakeoffMeasurement', 'wall_segments_json')
        segs = json ? (JSON.parse(json) rescue []) : []
        segs.reject! { |s| s['entityID'] == seg_eid }
        @measurement_group.set_attribute('TakeoffMeasurement', 'wall_segments_json', JSON.generate(segs))

        # Recompute
        total_lf = segs.sum { |s| (s['length_ft'] || 0).to_f }
        @measurement_group.set_attribute('TakeoffMeasurement', 'total_lf', total_lf.round(2))
        @measurement_group.set_attribute('TakeoffMeasurement', 'segment_count', segs.length)

        oc = @measurement_group.get_attribute('TakeoffMeasurement', 'oc_spacing') || 16
        waste = 5
        cfg_json = @measurement_group.get_attribute('TakeoffMeasurement', 'wall_config')
        if cfg_json
          cfg = JSON.parse(cfg_json) rescue {}
          waste = cfg['waste_pct'] || 5
        end
        total_in = segs.sum { |s| (s['length_in'] || 0).to_f }
        total_studs = (total_in / oc.to_f).ceil
        total_studs = (total_studs * (1 + waste.to_f / 100.0)).ceil
        @measurement_group.set_attribute('TakeoffMeasurement', 'total_studs', total_studs)

        details = segs.map { |s| { 'lf' => s['length_ft'], 'h' => s['height_ft'], 'nominal' => s['nominal'] } }
        @measurement_group.set_attribute('TakeoffMeasurement', 'wall_details_json', JSON.generate(details))

        summary = segs.length > 0 ? "#{segs.length} seg, #{total_lf.round(1)} LF" : "0 LF"
        @measurement_group.name = "TO_WALL: #{@label} — #{summary}"

        model.commit_operation

        Sketchup.status_text = "Remove Wall [#{@label}]: #{segs.length} segments. Escape to finish."
      rescue => e
        model.abort_operation
        puts "RemoveWallSegment error: #{e.message}"
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

  def self.activate_wall_tool(opts = {})
    Sketchup.active_model.select_tool(MeasureWallTool.new(opts))
  end

  def self.activate_remove_wall_tool(group_eid)
    Sketchup.active_model.select_tool(RemoveWallSegmentTool.new(group_eid))
  end

  def self.update_wall_label(group_eid, new_label)
    grp = find_entity(group_eid.to_i)
    return unless grp && grp.valid?
    m = Sketchup.active_model
    m.start_operation('Rename WALL Measurement', true)
    grp.set_attribute('TakeoffMeasurement', 'label', new_label)
    total_lf = grp.get_attribute('TakeoffMeasurement', 'total_lf') || 0
    seg_count = grp.get_attribute('TakeoffMeasurement', 'segment_count') || 0
    summary = seg_count > 0 ? "#{seg_count} seg, #{total_lf} LF" : "0 LF"
    grp.name = "TO_WALL: #{new_label} — #{summary}"
    m.commit_operation
  end

  def self.update_wall_color(group_eid, color_rgb)
    grp = find_entity(group_eid.to_i)
    return unless grp && grp.valid?
    m = Sketchup.active_model
    require 'json'
    m.start_operation('Change WALL Color', true)
    grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([color_rgb[0], color_rgb[1], color_rgb[2], 160]))
    r, g, b = color_rgb
    mat_name = "FF_WALL_#{grp.entityID}"
    mat = m.materials[mat_name] || m.materials.add(mat_name)
    mat.color = Sketchup::Color.new(r, g, b)
    mat.alpha = 0.5
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
