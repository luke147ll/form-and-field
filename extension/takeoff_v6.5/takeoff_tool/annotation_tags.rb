module TakeoffTool
  unless defined?(ANNO_TAG_MODES)
  ANNO_TAG_MODES = {
    'grid_num'   => { prefix: '',  label: 'Gridline (1,2,3)', color: [137, 180, 250], stacked: false },
    'grid_alpha' => { prefix: '',  label: 'Gridline (A,B,C)', color: [137, 180, 250], stacked: false },
    'section'    => { prefix: '',  label: 'Section',           color: [203, 166, 247], stacked: true  },
    'detail'     => { prefix: '',  label: 'Detail',            color: [166, 227, 161], stacked: true  }
  }
  ANNO_TEXT_HEIGHT   = 1.5    # inches
  ANNO_MIN_RADIUS    = 2.0    # inches
  ANNO_BORDER_WIDTH  = 0.15   # inches
  ANNO_CIRCLE_SEGS   = 32
  ANNO_STANDOFF      = 0.1    # inches above surface
  ANNO_SCALE         = 5.0    # 5x scale for model-scale readability
  end # unless defined?

  # ═══════════════════════════════════════════════════════════════
  # ANNOTATION TAG TOOL — Gridlines, Sections, Details
  #
  # Places round circle tags with auto-incrementing labels.
  # Section/Detail modes show stacked number/sheet (e.g., 1/A4.0).
  # Stores elevation attributes so section alignment picks them up.
  # ═══════════════════════════════════════════════════════════════
  class AnnotationTagTool
    VK_RIGHT = 39  # Red (X)
    VK_LEFT  = 37  # Green (Y)
    VK_UP    = 38  # Blue (Z)
    VK_DOWN  = 40  # Unlock

    AXIS_COLORS = {
      red:   Sketchup::Color.new(255, 0, 0),
      green: Sketchup::Color.new(0, 180, 0),
      blue:  Sketchup::Color.new(0, 0, 255)
    }.freeze

    def initialize
      @ip = Sketchup::InputPoint.new
      @mode = 'grid_num'
      @counter = 1
      @prefix = ''
      @sheet = ''       # sheet number for section/detail (e.g., "A4.0")
      @tags_placed = 0
      @benchmark = nil
      @panel = nil

      # Axis lock (arrow keys — constrains position AND sets direction)
      @axis_lock = nil      # :red, :green, :blue, or nil
      @lock_origin = nil    # Geom::Point3d — anchor for constraint
      @constrained_pt = nil # Geom::Point3d — projected position
      @last_placed = nil    # Geom::Point3d — last tag position

      # Plane direction (panel dropdown — sets direction only, no position constraint)
      @plane_dir = nil      # :red, :green, or nil
    end

    def activate
      @benchmark = TakeoffTool.get_elevation_benchmark
      load_existing_counter
      open_panel
      update_status
    end

    def deactivate(view)
      close_panel
      view.invalidate
    end

    def resume(view)
      update_status
      view.invalidate
    end

    # ── input ──

    def onMouseMove(flags, x, y, view)
      @ip.pick(view, x, y)
      @constrained_pt = nil

      if @ip.valid?
        pt = @ip.position

        # Apply axis constraint
        if @axis_lock && @lock_origin
          pt = constrain_to_axis(pt, @lock_origin, @axis_lock)
          @constrained_pt = pt
        end

        tip = display_label
        if @benchmark
          elev = TakeoffTool.calculate_elevation(pt)
          tip = "#{tip} — #{TakeoffTool.format_elevation(elev, @benchmark['unit'])}" if elev
        else
          tip = "#{tip} — Z: #{'%.1f' % (pt.z / 12.0)}'"
        end
        lock_name = @axis_lock ? " [#{@axis_lock.to_s.capitalize} axis]" : ""
        view.tooltip = "#{tip}#{lock_name}"
      end
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      @ip.pick(view, x, y)
      return unless @ip.valid?

      pt = @constrained_pt || @ip.position
      place_tag(pt.clone, view)
      @last_placed = pt.clone
      # Update lock origin to new position so next tag stays on axis
      @lock_origin = pt.clone if @axis_lock
      @counter += 1
      @tags_placed += 1
      update_panel
      update_status
      view.invalidate
    end

    def onKeyDown(key, repeat, flags, view)
      case key
      when 27
        Sketchup.active_model.select_tool(nil)
      when VK_RIGHT
        toggle_axis_lock(:red, view)
      when VK_LEFT
        toggle_axis_lock(:green, view)
      when VK_UP
        toggle_axis_lock(:blue, view)
      when VK_DOWN
        @axis_lock = nil; @constrained_pt = nil
        Sketchup.status_text = "Axis lock cleared"
        view.invalidate
      end
    end

    def onCancel(reason, view)
      Sketchup.active_model.select_tool(nil)
    end

    # ── drawing ──

    def draw(view)
      @ip.draw(view) if @ip.valid?

      # Axis lock line
      if @axis_lock && @lock_origin
        color = AXIS_COLORS[@axis_lock]
        view.line_stipple = '-'
        view.line_width = 2
        view.drawing_color = color
        dir = axis_vector(@axis_lock)
        p1 = @lock_origin.offset(dir, -10000)
        p2 = @lock_origin.offset(dir,  10000)
        view.draw(GL_LINES, p1, p2)
        view.line_stipple = ''

        # Constrained point marker
        if @constrained_pt
          view.draw_points([@constrained_pt], 10, 4, color)
        end
      end

      # Plane direction line — shows the cut/gridline direction
      eff_dir = @axis_lock || @plane_dir
      if eff_dir && @ip.valid?
        pt = @constrained_pt || @ip.position
        # Plane direction is perpendicular to the lock axis in XY
        plane_dir = case eff_dir
                    when :red   then Geom::Vector3d.new(0, 1, 0)  # plane along Y
                    when :green then Geom::Vector3d.new(1, 0, 0)  # plane along X
                    else nil
                    end
        if plane_dir
          len = 120  # inches — visible at model scale
          p1 = pt.offset(plane_dir, -len)
          p2 = pt.offset(plane_dir,  len)
          clr = Sketchup::Color.new(249, 226, 175, 120)
          view.drawing_color = clr
          view.line_width = 1; view.line_stipple = '-'
          view.draw(GL_LINES, p1, p2)
          view.line_stipple = ''
        end
      end

      # Label preview at cursor
      if @ip.valid?
        pt = @constrained_pt || @ip.position
        screen = view.screen_coords(pt)
        screen.y -= 25
        cfg = ANNO_TAG_MODES[@mode]
        color = Sketchup::Color.new(*cfg[:color])
        view.draw_text(screen, display_label, color: color, size: 14)
      end
    end

    def getExtents
      Geom::BoundingBox.new
    end

    private

    # ── axis lock ──

    def toggle_axis_lock(axis, view)
      if @axis_lock == axis
        @axis_lock = nil; @constrained_pt = nil
        Sketchup.status_text = "Axis lock cleared"
      else
        @axis_lock = axis
        # Lock origin = last placed tag, or current cursor position
        @lock_origin = @last_placed ? @last_placed.clone : (@ip.valid? ? @ip.position.clone : ORIGIN)
        Sketchup.status_text = "Locked to #{axis.to_s.capitalize} axis"
      end
      view.invalidate
    end

    def constrain_to_axis(pt, origin, axis)
      case axis
      when :red   then Geom::Point3d.new(pt.x, origin.y, origin.z)
      when :green then Geom::Point3d.new(origin.x, pt.y, origin.z)
      when :blue  then Geom::Point3d.new(origin.x, origin.y, pt.z)
      else pt
      end
    end

    def axis_vector(axis)
      case axis
      when :red   then Geom::Vector3d.new(1, 0, 0)
      when :green then Geom::Vector3d.new(0, 1, 0)
      when :blue  then Geom::Vector3d.new(0, 0, 1)
      end
    end

    # ── label logic ──

    def number_label
      @mode == 'grid_alpha' ? alpha_label(@counter) : @counter.to_s
    end

    # Full display label for tooltips, status bar, group name
    def display_label
      num = "#{@prefix}#{number_label}"
      if stacked_mode? && !@sheet.empty?
        "#{num}/#{@sheet}"
      else
        num
      end
    end

    def stacked_mode?
      ANNO_TAG_MODES[@mode] && ANNO_TAG_MODES[@mode][:stacked]
    end

    def alpha_label(n)
      n -= 1  # 1-based → 0-based
      label = ''
      loop do
        label = (65 + n % 26).chr + label
        n = n / 26 - 1
        break if n < 0
      end
      label
    end

    # ── tag placement ──

    def place_tag(point, view)
      model = Sketchup.active_model
      model.start_operation('Place Annotation Tag', true)

      cfg = ANNO_TAG_MODES[@mode]
      label = display_label
      num = "#{@prefix}#{number_label}"

      tag_layer = model.layers[ELEV_TAG] || model.layers.add(ELEV_TAG)
      grp = model.active_entities.add_group
      grp.layer = tag_layer
      grp.name = "FF_TAG: #{label}"

      if stacked_mode? && !@sheet.empty?
        build_stacked_tag(grp.entities, model, num, @sheet, cfg[:color])
      else
        build_round_tag(grp.entities, model, num, cfg[:color])
      end

      # Scale 5x — annotation tags need to be readable at model scale
      scale = Geom::Transformation.scaling(ORIGIN, ANNO_SCALE)
      grp.entities.transform_entities(scale, grp.entities.to_a)

      # Tag is built flat in XY plane — readable from top-down

      # Center at click point
      tag_bb = Geom::BoundingBox.new
      grp.entities.each { |e| tag_bb.add(e.bounds) }
      cx = (tag_bb.min.x + tag_bb.max.x) / 2.0
      cy = (tag_bb.min.y + tag_bb.max.y) / 2.0
      cz = (tag_bb.min.z + tag_bb.max.z) / 2.0
      offset = Geom::Vector3d.new(point.x - cx, point.y - cy, point.z + ANNO_STANDOFF - cz)
      grp.transform!(Geom::Transformation.new(offset))

      # Attributes — same keys as elevation tags for section alignment compatibility
      elev = @benchmark ? TakeoffTool.calculate_elevation(point) : nil
      elev_label = if elev
        TakeoffTool.format_elevation(elev, @benchmark['unit'])
      else
        "Z: #{'%.1f' % (point.z / 12.0)}'"
      end

      require 'json'
      grp.set_attribute('TakeoffMeasurement', 'type', 'ELEV')
      grp.set_attribute('TakeoffMeasurement', 'category', 'Elevation Tags')
      grp.set_attribute('TakeoffMeasurement', 'elevation', elev || 0)
      grp.set_attribute('TakeoffMeasurement', 'elevation_label', elev_label)
      grp.set_attribute('TakeoffMeasurement', 'custom_label', label)
      grp.set_attribute('TakeoffMeasurement', 'tag_mode', @mode)
      grp.set_attribute('TakeoffMeasurement', 'tag_counter', @counter)
      grp.set_attribute('TakeoffMeasurement', 'tag_sheet', @sheet) unless @sheet.empty?
      grp.set_attribute('TakeoffMeasurement', 'benchmark_name', @benchmark ? @benchmark['name'] : '')
      grp.set_attribute('TakeoffMeasurement', 'benchmark_unit', @benchmark ? @benchmark['unit'] : 'feet')
      grp.set_attribute('TakeoffMeasurement', 'point', JSON.generate([point.x.to_f, point.y.to_f, point.z.to_f]))
      # Effective direction: arrow-key axis lock takes priority, then panel dropdown
      eff_dir = @axis_lock || @plane_dir
      grp.set_attribute('TakeoffMeasurement', 'axis_lock', eff_dir ? eff_dir.to_s : '')
      # Plane angle: direction of the cut/gridline in plan view (radians from X axis)
      # Red lock → tags at different X → plane runs along Y → angle = π/2
      # Green lock → tags at different Y → plane runs along X → angle = 0
      pa = case eff_dir
           when :red   then Math::PI / 2.0
           when :green then 0.0
           else nil
           end
      grp.set_attribute('TakeoffMeasurement', 'plane_angle', pa) if pa
      grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
      grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      grp.set_attribute('TakeoffMeasurement', 'note', "#{label} #{elev_label}")

      TakeoffTool.entity_registry[grp.entityID] = grp
      model.commit_operation

      Dashboard.send_measurement_data rescue nil
      puts "AnnotationTag: #{label} at Z=#{'%.1f' % point.z}\" (#{elev_label})"
    end

    # ── round tag geometry (gridlines — single label) ──

    def build_round_tag(ents, model, label_text, bg_color)
      mats = ensure_materials(model, bg_color)

      ents.add_3d_text(label_text, TextAlignCenter, "Arial", true, false,
                       ANNO_TEXT_HEIGHT, 0.0, 0.0, true, 0.2)

      text_bb = Geom::BoundingBox.new
      ents.each { |e| text_bb.add(e.bounds) }
      tw = text_bb.max.x - text_bb.min.x
      th = text_bb.max.y - text_bb.min.y
      tcx = (text_bb.min.x + text_bb.max.x) / 2.0
      tcy = (text_bb.min.y + text_bb.max.y) / 2.0

      half_diag = Math.sqrt((tw / 2.0)**2 + (th / 2.0)**2)
      radius = [half_diag + 0.6, ANNO_MIN_RADIUS].max

      border_face = add_circle_face(ents, tcx, tcy, -0.4, radius + ANNO_BORDER_WIDTH)
      apply_mat(border_face, mats[:border])

      fill_face = add_circle_face(ents, tcx, tcy, -0.2, radius)
      apply_mat(fill_face, mats[:fill])

      ents.grep(Sketchup::Face).each do |f|
        next if f == border_face || f == fill_face
        apply_mat(f, mats[:text])
      end
    end

    # ── stacked tag geometry (sections/details — number over sheet) ──
    #
    #     ┌─────────┐
    #     │    1    │  ← section/detail number (top)
    #     │─────────│  ← divider line
    #     │  A4.0   │  ← sheet number (bottom)
    #     └─────────┘
    #

    def build_stacked_tag(ents, model, top_text, bottom_text, bg_color)
      mats = ensure_materials(model, bg_color)

      top_h = ANNO_TEXT_HEIGHT
      bot_h = ANNO_TEXT_HEIGHT * 0.7   # sheet text slightly smaller
      gap = top_h * 0.35              # space for divider line

      # Add top text (number) to a temp group so we can measure + position
      top_grp = ents.add_group
      top_grp.entities.add_3d_text(top_text, TextAlignCenter, "Arial", true, false,
                                    top_h, 0.0, 0.0, true, 0.2)
      top_bb = Geom::BoundingBox.new
      top_grp.entities.each { |e| top_bb.add(e.bounds) }

      # Add bottom text (sheet)
      bot_grp = ents.add_group
      bot_grp.entities.add_3d_text(bottom_text, TextAlignCenter, "Arial", true, false,
                                    bot_h, 0.0, 0.0, true, 0.15)
      bot_bb = Geom::BoundingBox.new
      bot_grp.entities.each { |e| bot_bb.add(e.bounds) }

      # Calculate total height and centering
      total_h = (top_bb.max.y - top_bb.min.y) + gap + (bot_bb.max.y - bot_bb.min.y)
      max_w = [top_bb.max.x - top_bb.min.x, bot_bb.max.x - bot_bb.min.x].max

      # Center X for both texts
      top_cx = (top_bb.min.x + top_bb.max.x) / 2.0
      bot_cx = (bot_bb.min.x + bot_bb.max.x) / 2.0
      center_x = [top_cx, bot_cx].max  # align to widest

      # Position bottom text at y=0
      bot_dy = -bot_bb.min.y
      bot_dx = center_x - bot_cx
      bot_grp.transform!(Geom::Transformation.new(Geom::Vector3d.new(bot_dx, bot_dy, 0)))

      # Position top text above gap
      top_base_y = (bot_bb.max.y - bot_bb.min.y) + bot_dy + gap
      top_dy = top_base_y - top_bb.min.y
      top_dx = center_x - top_cx
      top_grp.transform!(Geom::Transformation.new(Geom::Vector3d.new(top_dx, top_dy, 0)))

      # Explode temp groups so faces are in ents directly
      top_grp.explode
      bot_grp.explode

      # Measure final text bounds
      text_bb = Geom::BoundingBox.new
      ents.each { |e| text_bb.add(e.bounds) }
      tw = text_bb.max.x - text_bb.min.x
      th = text_bb.max.y - text_bb.min.y
      tcx = (text_bb.min.x + text_bb.max.x) / 2.0
      tcy = (text_bb.min.y + text_bb.max.y) / 2.0

      # Circle radius
      half_diag = Math.sqrt((tw / 2.0)**2 + (th / 2.0)**2)
      radius = [half_diag + 0.6, ANNO_MIN_RADIUS].max

      # Border circle
      border_face = add_circle_face(ents, tcx, tcy, -0.4, radius + ANNO_BORDER_WIDTH)
      apply_mat(border_face, mats[:border])

      # Fill circle
      fill_face = add_circle_face(ents, tcx, tcy, -0.2, radius)
      apply_mat(fill_face, mats[:fill])

      # Divider line across the circle at the gap midpoint
      divider_y = (bot_bb.max.y - bot_bb.min.y) + bot_dy + gap / 2.0
      div_z = -0.1  # in front of fill, behind text
      ents.add_edges(
        Geom::Point3d.new(tcx - radius * 0.85, divider_y, div_z),
        Geom::Point3d.new(tcx + radius * 0.85, divider_y, div_z)
      )

      # Apply materials — text faces get dark text, skip circle faces
      ents.grep(Sketchup::Face).each do |f|
        next if f == border_face || f == fill_face
        apply_mat(f, mats[:text])
      end

      # Thicken divider edge
      ents.grep(Sketchup::Edge).each do |e|
        if (e.start.position.z - div_z).abs < 0.05 && (e.end.position.z - div_z).abs < 0.05
          e.material = mats[:border]
        end
      end
    end

    # ── shared geometry helpers ──

    def add_circle_face(ents, cx, cy, z, radius)
      pts = (0...ANNO_CIRCLE_SEGS).map do |i|
        angle = 2.0 * Math::PI * i / ANNO_CIRCLE_SEGS
        Geom::Point3d.new(
          cx + radius * Math.cos(angle),
          cy + radius * Math.sin(angle),
          z
        )
      end
      ents.add_face(pts)
    rescue
      nil
    end

    def ensure_materials(model, bg_color)
      hex = '%02x%02x%02x' % bg_color[0..2]

      fill = model.materials["FF_Tag_#{hex}"] || begin
        m = model.materials.add("FF_Tag_#{hex}")
        m.color = Sketchup::Color.new(*bg_color)
        m.alpha = 0.90
        m
      end

      border = model.materials['FF_Tag_Border'] || begin
        m = model.materials.add('FF_Tag_Border')
        m.color = Sketchup::Color.new(49, 50, 68)
        m
      end

      text = model.materials['FF_Tag_DarkText'] || begin
        m = model.materials.add('FF_Tag_DarkText')
        m.color = Sketchup::Color.new(30, 30, 46)
        m
      end

      { fill: fill, border: border, text: text }
    end

    def apply_mat(face, mat)
      return unless face
      face.material = mat
      face.back_material = mat
    end

    # ── counter persistence ──

    def load_existing_counter
      model = Sketchup.active_model
      return unless model

      max_counter = 0
      model.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        next unless grp.get_attribute('TakeoffMeasurement', 'tag_mode') == @mode
        c = grp.get_attribute('TakeoffMeasurement', 'tag_counter')
        max_counter = [max_counter, c.to_i].max if c
      end
      @counter = max_counter > 0 ? max_counter + 1 : 1
    end

    # ── panel ──

    def open_panel
      close_panel

      @panel = UI::HtmlDialog.new(
        dialog_title: "Annotation Tags",
        preferences_key: "FFAnnotationTag2",
        width: 260, height: 420,
        left: 100, top: 200,
        resizable: false,
        style: UI::HtmlDialog::STYLE_UTILITY
      )

      @panel.add_action_callback('setMode') do |_ctx, mode|
        mode = mode.to_s
        if ANNO_TAG_MODES[mode]
          @mode = mode
          @prefix = ANNO_TAG_MODES[mode][:prefix]
          load_existing_counter
          update_panel
          update_status
        end
      end

      @panel.add_action_callback('setPrefix') do |_ctx, pfx|
        @prefix = pfx.to_s
        update_panel
      end

      @panel.add_action_callback('setSheet') do |_ctx, val|
        @sheet = val.to_s.strip
        update_panel
      end

      @panel.add_action_callback('setCounter') do |_ctx, val|
        n = val.to_i
        @counter = n if n > 0
        update_panel
      end

      @panel.add_action_callback('setPlaneDir') do |_ctx, val|
        @plane_dir = case val.to_s
                     when 'red'   then :red
                     when 'green' then :green
                     else nil
                     end
        Sketchup.active_model.active_view.invalidate
      end

      @panel.add_action_callback('skip') do |_ctx|
        Sketchup.active_model.select_tool(nil)
      end

      @panel.set_on_closed {
        @panel = nil
        Sketchup.active_model.select_tool(nil)
      }

      @prefix = ANNO_TAG_MODES[@mode][:prefix]
      @panel.set_html(panel_html)
      @panel.show

      UI.start_timer(0.2) do
        update_panel
      end
    end

    def close_panel
      if @panel
        @panel.set_on_closed {}
        @panel.close rescue nil
        @panel = nil
      end
    end

    def update_panel
      return unless @panel && @panel.visible?
      require 'json'
      cfg = ANNO_TAG_MODES[@mode]
      num = "#{@prefix}#{number_label}"
      @panel.execute_script("updateState(#{JSON.generate({
        mode: @mode,
        num: num,
        sheet: @sheet,
        stacked: cfg[:stacked],
        counter: @counter,
        prefix: @prefix,
        color: '#%02x%02x%02x' % cfg[:color],
        mode_label: cfg[:label],
        placed: @tags_placed,
        plane_dir: @plane_dir ? @plane_dir.to_s : ''
      })})") rescue nil
    end

    def update_status
      placed = @tags_placed > 0 ? " (#{@tags_placed} placed)" : ""
      bmk = @benchmark ? "#{@benchmark['name']}" : "No benchmark"
      Sketchup.status_text = "Annotation Tag#{placed}: #{display_label} — Click to place. #{bmk}. ESC to exit."
    end

    def panel_html
      mode_opts = ANNO_TAG_MODES.map { |k, v|
        sel = k == @mode ? ' selected' : ''
        "<option value=\"#{k}\"#{sel}>#{v[:label]}</option>"
      }.join

      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font:13px/1.4 'Segoe UI',system-ui,sans-serif;background:#1e1e2e;color:#cdd6f4;padding:14px}
        .hdr{font-size:11px;font-weight:700;color:#cba6f7;text-transform:uppercase;letter-spacing:1px;text-align:center;margin-bottom:12px}
        label{display:block;color:#a6adc8;font-size:11px;margin-bottom:3px;margin-top:10px;font-weight:600;text-transform:uppercase;letter-spacing:0.5px}
        label:first-of-type{margin-top:0}
        select,input[type=text],input[type=number]{width:100%;padding:7px 9px;background:#313244;color:#cdd6f4;border:1px solid #585b70;border-radius:5px;font-size:12px;font-family:inherit}
        select:focus,input:focus{outline:none;border-color:#89b4fa}
        .preview{text-align:center;margin:16px 0}
        .tag-circle{display:inline-flex;align-items:center;justify-content:center;
          width:80px;height:80px;border-radius:50%;border:3px solid #313244;
          font-weight:800;color:#1e1e2e;letter-spacing:1px;flex-direction:column}
        .tag-num{font-size:24px;line-height:1.1}
        .tag-div{width:60%;height:2px;background:#313244;margin:2px 0}
        .tag-sheet{font-size:13px;line-height:1.1}
        .counter-row{display:flex;gap:8px;align-items:flex-end}
        .counter-row .field{flex:1}
        .counter-row .field input{width:100%}
        .sheet-row{display:none}
        .sheet-row.visible{display:block}
        .plane-row{display:none}
        .plane-row.visible{display:block}
        .placed{text-align:center;color:#6c7086;font-size:11px;margin-top:6px}
        .info{color:#6c7086;font-size:10px;margin-top:8px;padding:6px 8px;background:#313244;border-radius:4px;line-height:1.5}
        .btns{display:flex;gap:8px;margin-top:14px}
        .btn{flex:1;padding:7px 0;border:none;border-radius:5px;font-size:12px;font-weight:600;cursor:pointer;font-family:inherit;text-align:center}
        .btn-exit{background:#45475a;color:#cdd6f4}.btn-exit:hover{background:#585b70}
        </style></head><body>
        <div class="hdr">Annotation Tags</div>

        <label>Tag Type</label>
        <select id="mode" onchange="sketchup.setMode(this.value)">#{mode_opts}</select>

        <div class="preview">
          <div class="tag-circle" id="circle">
            <span class="tag-num" id="tagNum">#{@prefix}#{number_label}</span>
            <div class="tag-div" id="tagDiv" style="display:none"></div>
            <span class="tag-sheet" id="tagSheet" style="display:none"></span>
          </div>
        </div>

        <div class="counter-row">
          <div class="field">
            <label>Prefix</label>
            <input id="prefix" type="text" value="#{@prefix}" maxlength="4"
              oninput="sketchup.setPrefix(this.value)">
          </div>
          <div class="field">
            <label>Next #</label>
            <input id="counter" type="number" min="1" value="#{@counter}"
              onchange="sketchup.setCounter(this.value)">
          </div>
        </div>

        <div class="sheet-row" id="sheetRow">
          <label>Sheet Number</label>
          <input id="sheet" type="text" value="" placeholder="e.g. A4.0"
            oninput="sketchup.setSheet(this.value)">
        </div>

        <div class="plane-row" id="planeRow">
          <label>Plane Direction</label>
          <select id="planeDir" onchange="sketchup.setPlaneDir(this.value)">
            <option value="">None</option>
            <option value="red">Red (→ plane along Y)</option>
            <option value="green">Green (→ plane along X)</option>
          </select>
        </div>

        <div class="placed" id="placed"></div>

        <div class="info">
          Click any point to place a tag. Tags store elevation data for section alignment.
        </div>

        <div class="btns">
          <button class="btn btn-exit" onclick="sketchup.skip()">Done</button>
        </div>

        <script>
        function updateState(d){
          var circle = document.getElementById('circle');
          var numEl = document.getElementById('tagNum');
          var divEl = document.getElementById('tagDiv');
          var sheetEl = document.getElementById('tagSheet');
          var sheetRow = document.getElementById('sheetRow');

          circle.style.backgroundColor = d.color;
          numEl.textContent = d.num;

          var planeRow = document.getElementById('planeRow');
          if(d.stacked){
            sheetRow.className = 'sheet-row visible';
            planeRow.className = 'plane-row visible';
            if(d.sheet && d.sheet.length > 0){
              divEl.style.display = '';
              sheetEl.style.display = '';
              sheetEl.textContent = d.sheet;
            } else {
              divEl.style.display = 'none';
              sheetEl.style.display = 'none';
            }
          } else {
            sheetRow.className = 'sheet-row';
            planeRow.className = 'plane-row';
            divEl.style.display = 'none';
            sheetEl.style.display = 'none';
          }

          document.getElementById('prefix').value = d.prefix;
          document.getElementById('counter').value = d.counter;
          document.getElementById('planeDir').value = d.plane_dir || '';
          document.getElementById('placed').textContent = d.placed > 0 ? d.placed + ' tag' + (d.placed > 1 ? 's' : '') + ' placed' : '';
        }
        </script>
        </body></html>
      HTML
    end
  end

  def self.activate_annotation_tag_tool
    Sketchup.active_model.select_tool(AnnotationTagTool.new)
  end
end
