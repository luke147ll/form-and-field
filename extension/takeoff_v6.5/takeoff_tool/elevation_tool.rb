module TakeoffTool
  unless defined?(ELEV_TAG)
  ELEV_TAG = 'FF_Elevation_Tags'
  ELEV_BENCHMARK_KEY = 'elevation_benchmark'
  ELEV_MAUVE = [203, 166, 247]
  ELEV_TEXT_COLOR = [30, 30, 46]
  ELEV_STANDOFF = 0.1        # inches — tiny gap so pointer nearly touches surface
  ELEV_OUTLINE_WIDTH = 0.2   # inches — dark border thickness
  ELEV_HORIZONTAL_THRESHOLD = 2.0    # degrees — below = horizontal
  ELEV_WALL_THRESHOLD = 89.5         # degrees — above = vertical wall
  ELEV_SLOPE_COLOR = [249, 226, 175] # #f9e2af Catppuccin yellow
  ELEV_LABEL_TEXT_HEIGHT = 1.8       # inches — label text height
  ELEV_LABEL_PAD_X = 1.5            # inches — label horizontal padding
  ELEV_LABEL_PAD_Z = 0.6            # inches — label vertical padding
  ELEV_POINTER_HEIGHT = 0.5         # inches — callout pointer below label
  end # unless defined?(ELEV_TAG)

  # ═══════════════════════════════════════════════════════════════
  # BENCHMARK TOOL — Click a face to set elevation reference point
  # ═══════════════════════════════════════════════════════════════
  class BenchmarkTool
    def initialize
      @ip = Sketchup::InputPoint.new
      @hover_face = nil
      @hover_transform = nil
      @dialog_open = false
      @click_point = nil
      @is_horizontal = true
    end

    def activate
      @hover_face = nil
      @hover_transform = nil
      @dialog_open = false
      Sketchup.status_text = "Benchmark Tool: Click a horizontal face to set the elevation benchmark."
    end

    def deactivate(view)
      @bmk_dlg.close if @bmk_dlg rescue nil
      view.invalidate
    end

    def resume(view)
      Sketchup.status_text = "Benchmark Tool: Click a horizontal face to set the elevation benchmark."
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      return if @dialog_open
      ph = view.pick_helper
      ph.do_pick(x, y)

      face = nil; xform = nil
      ph.count.times do |i|
        leaf = ph.leaf_at(i)
        if leaf.is_a?(Sketchup::Face)
          face = leaf; xform = ph.transformation_at(i); break
        end
      end
      if !face
        path = ph.path_at(0)
        if path && path.last.is_a?(Sketchup::Face)
          face = path.last; xform = ph.transformation_at(0)
        end
      end

      if face && !face.equal?(@hover_face)
        @hover_face = face
        @hover_transform = xform || Geom::Transformation.new
        view.invalidate
      elsif !face && @hover_face
        @hover_face = nil; @hover_transform = nil
        view.invalidate
      end
    end

    def onLButtonDown(flags, x, y, view)
      return if @dialog_open
      return unless @hover_face

      @ip.pick(view, x, y)
      return unless @ip.valid?
      @click_point = @ip.position

      # Check horizontality using corrected world-space normal
      normal = TakeoffTool.get_world_normal(@hover_face, @hover_transform)
      z_dot = normal.dot(Geom::Vector3d.new(0, 0, 1)).abs
      @is_horizontal = z_dot > 0.95

      show_benchmark_dialog(view)
    end

    def draw(view)
      return if @dialog_open
      if @hover_face
        draw_face_highlight(view, @hover_face, @hover_transform,
          Sketchup::Color.new(203, 166, 247, 60))
      end
    end

    def getExtents
      Geom::BoundingBox.new
    end

    private

    def draw_face_highlight(view, face, xform, color)
      begin
        mesh = face.mesh(0)
        pts = []
        (1..mesh.count_points).each do |i|
          pt = mesh.point_at(i)
          pts << (xform ? xform * pt : pt)
        end
        return if pts.length < 3
        view.drawing_color = color
        view.draw(GL_POLYGON, pts)
      rescue
      end
    end

    def show_benchmark_dialog(view)
      existing = TakeoffTool.get_elevation_benchmark
      default_name = existing ? existing['name'] : 'Benchmark'
      default_elev = existing ? existing['elevation'] : 0.0
      default_unit = existing ? existing['unit'] : 'feet'
      warn_html = @is_horizontal ? '' : '<div style="color:#f38ba8;font-size:11px;margin-top:8px">Warning: Selected face is not horizontal.</div>'

      html = <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <style>#{PICK_DIALOG_CSS}
        body{overflow-y:auto}
        </style></head><body>
        <h1>Set Elevation Benchmark</h1>
        <label>Benchmark Name</label>
        <input id="name" type="text" value="#{default_name.to_s.gsub('"', '&quot;')}">
        <label>Elevation</label>
        <input id="elev" type="number" step="any" value="#{default_elev}">
        <label>Unit</label>
        <select id="unit">
          <option value="feet"#{default_unit == 'feet' ? ' selected' : ''}>Feet</option>
          <option value="inches"#{default_unit == 'inches' ? ' selected' : ''}>Inches</option>
          <option value="meters"#{default_unit == 'meters' ? ' selected' : ''}>Meters</option>
        </select>
        #{warn_html}
        <div class="buttons">
          <button class="btn btn-cancel" onclick="sketchup.cancel()">Cancel</button>
          <button class="btn btn-ok" onclick="doOk()">OK</button>
        </div>
        <script>
        function doOk(){
          sketchup.ok(JSON.stringify({
            name: document.getElementById('name').value.trim(),
            elev: parseFloat(document.getElementById('elev').value) || 0,
            unit: document.getElementById('unit').value
          }));
        }
        document.addEventListener('keydown',function(e){
          if(e.key==='Escape')sketchup.cancel();
          if(e.key==='Enter')doOk();
        });
        </script>
        </body></html>
      HTML

      @bmk_dlg.close if @bmk_dlg rescue nil
      @bmk_dlg = UI::HtmlDialog.new(
        dialog_title: "Set Elevation Benchmark",
        preferences_key: "FFBenchmark",
        width: 320, height: 340,
        left: 200, top: 200,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      click_pt = @click_point.clone

      @bmk_dlg.add_action_callback('ok') do |_ctx, json_str|
        @bmk_dlg.close rescue nil
        @dialog_open = false
        require 'json'
        data = JSON.parse(json_str.to_s)
        name = data['name'].to_s
        name = 'Benchmark' if name.empty?
        TakeoffTool.set_elevation_benchmark(name, data['elev'], data['unit'], click_pt)
        Sketchup.status_text = "Benchmark set: #{name} at EL. #{data['elev']} #{data['unit']}"
        Sketchup.active_model.select_tool(nil)
      end

      @bmk_dlg.add_action_callback('cancel') do |_ctx|
        @bmk_dlg.close rescue nil
        @dialog_open = false
        Sketchup.status_text = "Benchmark cancelled."
      end

      @dialog_open = true
      @bmk_dlg.set_html(html)
      @bmk_dlg.show
    end
  end

  # ═══════════════════════════════════════════════════════════════
  # ELEVATION TAG TOOL — Click faces to place elevation tags
  # ═══════════════════════════════════════════════════════════════
  class ElevationTagTool
    def initialize
      @ip = Sketchup::InputPoint.new
      @hover_face = nil
      @hover_transform = nil
      @tags_placed = 0
      @benchmark = nil
    end

    def activate
      @benchmark = TakeoffTool.get_elevation_benchmark
      unless @benchmark
        UI.messagebox("No elevation benchmark set.\nPlease set a benchmark first using the Set Benchmark tool.")
        Sketchup.active_model.select_tool(nil)
        return
      end
      @hover_face = nil
      @hover_transform = nil
      @tags_placed = 0
      update_status
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      update_status
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      @ip.pick(view, x, y)
      ph = view.pick_helper
      ph.do_pick(x, y)

      face = nil; xform = nil
      ph.count.times do |i|
        leaf = ph.leaf_at(i)
        if leaf.is_a?(Sketchup::Face)
          face = leaf; xform = ph.transformation_at(i); break
        end
      end
      if !face
        path = ph.path_at(0)
        if path && path.last.is_a?(Sketchup::Face)
          face = path.last; xform = ph.transformation_at(0)
        end
      end

      @hover_face = face
      @hover_transform = xform || Geom::Transformation.new

      if @ip.valid? && @benchmark
        elev = TakeoffTool.calculate_elevation(@ip.position)
        if elev
          tip = TakeoffTool.format_elevation(elev, @benchmark['unit'])
          if @hover_face
            sa = TakeoffTool.face_slope_angle(@hover_face, @hover_transform)
            if sa > ELEV_HORIZONTAL_THRESHOLD && sa < ELEV_WALL_THRESHOLD
              tip = "#{tip}  (#{sa.round(1)} slope)"
            elsif sa >= ELEV_WALL_THRESHOLD
              tip = "#{tip}  (wall)"
            end
          end
          view.tooltip = tip
        end
      end

      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      @ip.pick(view, x, y)
      return unless @ip.valid?
      return unless @benchmark
      return unless @hover_face

      # Duplicate check — remove existing tag on this face (re-tag replaces)
      face_pid = (@hover_face.persistent_id rescue nil)
      TakeoffTool.remove_existing_face_tag(face_pid)

      click_pt = @ip.position
      slope_angle = TakeoffTool.face_slope_angle(@hover_face, @hover_transform)

      if slope_angle >= ELEV_WALL_THRESHOLD
        Sketchup.status_text = "Cannot tag vertical/wall faces."
        return
      elsif slope_angle > ELEV_HORIZONTAL_THRESHOLD
        # Sloped face — single slope info label at click point
        analysis = TakeoffTool.analyze_face_slope(@hover_face, @hover_transform)
        return unless analysis
        elev = TakeoffTool.calculate_elevation(click_pt)
        slope_text = TakeoffTool.format_slope_info(analysis[:rise], analysis[:run])
        TakeoffTool.create_elev_label(click_pt, slope_text, @hover_face, @hover_transform, @benchmark,
          color: ELEV_SLOPE_COLOR, dark_text: true, elevation: elev,
          slope_info: slope_text, slope_angle: slope_angle, view: view)
      else
        # Horizontal face — single clean elevation label at click point
        elev = TakeoffTool.calculate_elevation(click_pt)
        return unless elev
        label = TakeoffTool.format_elevation(elev, @benchmark['unit'])
        TakeoffTool.create_elev_label(click_pt, label, @hover_face, @hover_transform, @benchmark,
          elevation: elev, view: view)
      end

      @tags_placed += 1
      update_status
      view.invalidate
    end

    def draw(view)
      if @hover_face
        # Color face highlight based on slope
        hl_color = Sketchup::Color.new(203, 166, 247, 40)  # mauve default
        sa = TakeoffTool.face_slope_angle(@hover_face, @hover_transform)
        if sa > ELEV_HORIZONTAL_THRESHOLD && sa < ELEV_WALL_THRESHOLD
          hl_color = Sketchup::Color.new(249, 226, 175, 50)  # yellow for sloped
        elsif sa >= ELEV_WALL_THRESHOLD
          hl_color = Sketchup::Color.new(243, 139, 168, 40)  # red for wall
        end
        draw_face_highlight(view, @hover_face, @hover_transform, hl_color)
      end

      if @ip.valid? && @benchmark
        elev = TakeoffTool.calculate_elevation(@ip.position)
        if elev
          label = TakeoffTool.format_elevation(elev, @benchmark['unit'])
          draw_color = Sketchup::Color.new(203, 166, 247)
          if @hover_face
            sa = TakeoffTool.face_slope_angle(@hover_face, @hover_transform)
            if sa > ELEV_HORIZONTAL_THRESHOLD && sa < ELEV_WALL_THRESHOLD
              label = "#{label}  (#{sa.round(1)} slope)"
              draw_color = Sketchup::Color.new(*ELEV_SLOPE_COLOR)
            elsif sa >= ELEV_WALL_THRESHOLD
              label = "#{label}  (wall)"
              draw_color = Sketchup::Color.new(243, 139, 168)
            end
          end
          screen = view.screen_coords(@ip.position)
          screen.y -= 25
          view.draw_text(screen, label, color: draw_color)
        end
      end
    end

    def getExtents
      Geom::BoundingBox.new
    end

    private

    def draw_face_highlight(view, face, xform, color)
      begin
        mesh = face.mesh(0)
        pts = []
        (1..mesh.count_points).each do |i|
          pt = mesh.point_at(i)
          pts << (xform ? xform * pt : pt)
        end
        return if pts.length < 3
        view.drawing_color = color
        view.draw(GL_POLYGON, pts)
      rescue
      end
    end

    def update_status
      placed = @tags_placed > 0 ? " (#{@tags_placed} placed)" : ""
      Sketchup.status_text = "Elevation Tag#{placed}: Click faces to place elevation tags. ESC to exit."
      Sketchup.vcb_label = "Benchmark"
      Sketchup.vcb_value = @benchmark ? "#{@benchmark['name']} (#{@benchmark['elevation']} #{@benchmark['unit']})" : "Not set"
    end
  end

  # ═══════════════════════════════════════════════════════════════
  # MODULE-LEVEL HELPERS
  # ═══════════════════════════════════════════════════════════════

  def self.set_elevation_benchmark(name, elevation, unit, point)
    m = Sketchup.active_model
    return unless m

    require 'json'
    data = {
      'name' => name.to_s,
      'elevation' => elevation.to_f,
      'unit' => unit.to_s,
      'point' => [point.x.to_f, point.y.to_f, point.z.to_f],
      'z_inches' => point.z.to_f,
      'timestamp' => Time.now.to_s
    }
    m.set_attribute('FormAndField', ELEV_BENCHMARK_KEY, JSON.generate(data))

    place_benchmark_cpoint(m, point)
    puts "Takeoff: Elevation benchmark set: #{name} = #{elevation} #{unit} at Z=#{point.z.to_f.round(2)}"

    # Refresh dashboard benchmark display
    Dashboard.send_benchmark_data rescue nil
  end

  def self.get_elevation_benchmark
    m = Sketchup.active_model
    return nil unless m
    json = m.get_attribute('FormAndField', ELEV_BENCHMARK_KEY)
    return nil unless json && !json.empty?
    require 'json'
    JSON.parse(json) rescue nil
  end

  def self.calculate_elevation(world_point)
    bmk = get_elevation_benchmark
    return nil unless bmk

    delta_inches = world_point.z.to_f - bmk['z_inches'].to_f

    case bmk['unit']
    when 'feet'
      delta = delta_inches / 12.0
    when 'inches'
      delta = delta_inches
    when 'meters'
      delta = delta_inches * 0.0254
    else
      delta = delta_inches / 12.0
    end

    bmk['elevation'].to_f + delta
  end

  def self.format_elevation(elev_value, unit)
    case unit
    when 'feet'
      ft = elev_value.floor
      remaining = ((elev_value - ft).abs * 12).round
      if remaining >= 12
        ft += (elev_value >= 0 ? 1 : -1)
        remaining = 0
      end
      "EL. #{ft}'-#{remaining}\""
    when 'inches'
      "EL. #{elev_value.round(1)}\""
    when 'meters'
      "EL. #{'%.3f' % elev_value} m"
    else
      "EL. #{'%.2f' % elev_value}"
    end
  end

  # ── Slope analysis helpers ──

  def self.get_world_normal(face, transform)
    normal = face.normal
    if transform
      # Transformation * Vector3d applies rotation+scale only (no translation)
      # This correctly converts the local-space normal to world-space
      normal = transform * normal
      normal.normalize! if normal.length > 0.001
    end
    normal
  end

  def self.face_slope_angle(face, transform)
    normal = get_world_normal(face, transform)
    z_dot = normal.dot(Geom::Vector3d.new(0, 0, 1)).abs
    z_dot = [z_dot, 1.0].min
    Math.acos(z_dot) * 180.0 / Math::PI
  end

  def self.analyze_face_slope(face, transform)
    pts = face.outer_loop.vertices.map do |v|
      pt = v.position
      transform ? transform * pt : pt
    end
    return nil if pts.length < 3

    high_pt = pts.max_by { |p| p.z }
    low_pt = pts.min_by { |p| p.z }
    rise = (high_pt.z - low_pt.z).abs
    dx = high_pt.x - low_pt.x
    dy = high_pt.y - low_pt.y
    run = Math.sqrt(dx * dx + dy * dy)
    angle = face_slope_angle(face, transform)

    {
      high_pt: high_pt,
      low_pt: low_pt,
      rise: rise,
      run: run,
      angle: angle,
      mid_pt: Geom::Point3d.new(
        (high_pt.x + low_pt.x) / 2.0,
        (high_pt.y + low_pt.y) / 2.0,
        (high_pt.z + low_pt.z) / 2.0
      )
    }
  end

  def self.format_slope_info(rise, run)
    return "SLOPE: FLAT" if run < 0.001

    ipf = (rise / run) * 12.0
    eighths = (ipf * 8).round
    whole = eighths / 8
    frac = eighths % 8
    frac_str = case frac
    when 0 then nil
    when 1 then "1/8"
    when 2 then "1/4"
    when 3 then "3/8"
    when 4 then "1/2"
    when 5 then "5/8"
    when 6 then "3/4"
    when 7 then "7/8"
    end

    if whole > 0 && frac_str
      ipf_label = "#{whole}-#{frac_str}\"/ft"
    elsif whole > 0
      ipf_label = "#{whole}\"/ft"
    elsif frac_str
      ipf_label = "#{frac_str}\"/ft"
    else
      ipf_label = "0\"/ft"
    end

    pct = (rise / run) * 100.0
    "SLOPE: #{ipf_label}  #{'%.1f' % pct}%"
  end

  def self.place_benchmark_cpoint(model, point)
    model.start_operation('Set Benchmark Point', true)

    # Remove existing benchmark group
    model.entities.grep(Sketchup::Group).each do |grp|
      next unless grp.valid?
      if grp.get_attribute('TakeoffMeasurement', 'type') == 'BENCHMARK'
        grp.erase!
      end
    end

    tag = model.layers[ELEV_TAG] || model.layers.add(ELEV_TAG)
    grp = model.active_entities.add_group
    grp.layer = tag
    grp.name = "FF_Benchmark"
    grp.entities.add_cpoint(point)
    grp.set_attribute('TakeoffMeasurement', 'type', 'BENCHMARK')
    grp.set_attribute('TakeoffMeasurement', 'category', 'Elevation Tags')
    grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
    grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)

    TakeoffTool.entity_registry[grp.entityID] = grp
    model.commit_operation
  end

  # ── Face geometry helpers ──

  def self.face_center(face, transform)
    pts = face.outer_loop.vertices.map { |v| transform ? transform * v.position : v.position }
    cx = pts.sum { |p| p.x } / pts.length.to_f
    cy = pts.sum { |p| p.y } / pts.length.to_f
    cz = pts.sum { |p| p.z } / pts.length.to_f
    Geom::Point3d.new(cx, cy, cz)
  end

  def self.face_tag_scale(face, transform)
    pts = face.outer_loop.vertices.map { |v| transform ? transform * v.position : v.position }
    bb = Geom::BoundingBox.new
    pts.each { |p| bb.add(p) }
    diag = bb.min.distance(bb.max)
    # 1.0 at 120" diagonal (10ft face), scale proportionally
    scale = diag / 120.0
    [[scale, 0.3].max, 2.0].min
  end

  def self.remove_existing_face_tag(face_pid)
    return unless face_pid
    model = Sketchup.active_model
    return unless model
    pid_str = face_pid.to_s
    model.entities.grep(Sketchup::Group).each do |grp|
      next unless grp.valid?
      next unless grp.get_attribute('TakeoffMeasurement', 'type') == 'ELEV'
      if grp.get_attribute('TakeoffMeasurement', 'tagged_face_pid') == pid_str
        TakeoffTool.entity_registry.delete(grp.entityID)
        grp.erase!
        return
      end
    end
  end

  # ── Camera snap ──

  # Returns degrees to rotate label around Z so it faces the camera (snapped to nearest 90°)
  def self.camera_snap_angle(view)
    dir = view.camera.direction
    angle_rad = Math.atan2(dir.x, dir.y)
    angle_deg = angle_rad * 180.0 / Math::PI
    (angle_deg / 90.0).round * 90.0
  end

  # ── Tag creation ──

  def self.create_elev_label(point, text, face, transform, benchmark, opts = {})
    model = Sketchup.active_model
    model.start_operation('Place Elevation Label', true)

    tag_layer = model.layers[ELEV_TAG] || model.layers.add(ELEV_TAG)
    grp = model.active_entities.add_group
    grp.layer = tag_layer
    grp.name = "FF_ELEV: #{text}"
    ents = grp.entities

    color = opts[:color] || ELEV_MAUVE
    dark_text = opts[:dark_text] || false

    # Build callout label with text + pointer triangle
    build_rect_label(ents, model, text, color, dark_text)

    # Orient label: stand upright facing camera direction (snapped to nearest 90°)
    # Builds a rotation matrix that maps:
    #   text local X (reading) → camera right = (dy, -dx, 0)
    #   text local Y (ascender) → world up    = (0, 0, 1)
    #   text local Z (front)   → toward camera = (-dx, -dy, 0)
    # This avoids the mirror bug that occurred with separate upright + Z-rotation.
    cam_angle = opts[:view] ? camera_snap_angle(opts[:view]) : 0.0
    s_rad = cam_angle * Math::PI / 180.0
    cs = Math.cos(s_rad)
    sn = Math.sin(s_rad)
    # Column-major 4x4: col0=[cs,-sn,0,0] col1=[0,0,1,0] col2=[-sn,-cs,0,0] col3=[0,0,0,1]
    orient = Geom::Transformation.new([
      cs, -sn, 0, 0,
       0,   0, 1, 0,
      -sn, -cs, 0, 0,
       0,   0, 0, 1
    ])
    ents.transform_entities(orient, ents.to_a)

    # Scale based on face size
    scale = face_tag_scale(face, transform)
    if (scale - 1.0).abs > 0.01
      sc = Geom::Transformation.scaling(ORIGIN, scale)
      ents.transform_entities(sc, ents.to_a)
    end

    # Position: center label at point, floating above surface
    tag_bb = Geom::BoundingBox.new
    ents.each { |e| tag_bb.add(e.bounds) }
    cx = (tag_bb.min.x + tag_bb.max.x) / 2.0
    cy = (tag_bb.min.y + tag_bb.max.y) / 2.0
    cz = tag_bb.min.z

    offset = Geom::Vector3d.new(
      point.x - cx,
      point.y - cy,
      point.z + ELEV_STANDOFF - cz
    )
    grp.transform!(Geom::Transformation.new(offset))

    # Attributes
    require 'json'
    elev = opts[:elevation] || 0
    grp.set_attribute('TakeoffMeasurement', 'type', 'ELEV')
    grp.set_attribute('TakeoffMeasurement', 'category', 'Elevation Tags')
    grp.set_attribute('TakeoffMeasurement', 'elevation', elev)
    grp.set_attribute('TakeoffMeasurement', 'elevation_label', text)
    grp.set_attribute('TakeoffMeasurement', 'benchmark_name', benchmark['name'])
    grp.set_attribute('TakeoffMeasurement', 'benchmark_unit', benchmark['unit'])
    grp.set_attribute('TakeoffMeasurement', 'point', JSON.generate([point.x, point.y, point.z]))
    grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
    grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
    grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate(color + [230]))
    grp.set_attribute('TakeoffMeasurement', 'note', text)
    face_pid = (face.persistent_id rescue nil)
    grp.set_attribute('TakeoffMeasurement', 'tagged_face_pid', face_pid.to_s) if face_pid
    if opts[:slope_info]
      grp.set_attribute('TakeoffMeasurement', 'slope_info', opts[:slope_info])
      grp.set_attribute('TakeoffMeasurement', 'slope_angle', opts[:slope_angle])
    end

    TakeoffTool.entity_registry[grp.entityID] = grp
    model.commit_operation

    Dashboard.send_measurement_data rescue nil

    puts "Takeoff Elevation: #{text} at [#{point.x.round(1)}, #{point.y.round(1)}, #{point.z.round(1)}]"
    grp
  end

  def self.build_rect_label(ents, model, text, bg_color, dark_text = false)
    hex = '%02x%02x%02x' % bg_color[0..2]
    mat_name = "FF_Elev_#{hex}"
    mat = model.materials[mat_name]
    unless mat
      mat = model.materials.add(mat_name)
      mat.color = Sketchup::Color.new(*bg_color)
      mat.alpha = 0.88
    end

    border_mat = model.materials['FF_Elev_Border'] || begin
      m = model.materials.add('FF_Elev_Border')
      m.color = Sketchup::Color.new(49, 50, 68)
      m
    end

    text_mat_name = dark_text ? 'FF_Elev_DarkText' : 'FF_Elev_Text'
    text_color = dark_text ? Sketchup::Color.new(30, 30, 46) : Sketchup::Color.new(205, 214, 244)
    text_mat = model.materials[text_mat_name] || begin
      m = model.materials.add(text_mat_name)
      m.color = text_color
      m
    end

    ents.add_3d_text(text, TextAlignCenter, "Arial", true, false,
                     ELEV_LABEL_TEXT_HEIGHT, 0.0, 0.0, true, 0.2)

    text_bb = Geom::BoundingBox.new
    ents.each { |e| text_bb.add(e.bounds) }
    tw = text_bb.max.x - text_bb.min.x
    th = text_bb.max.y - text_bb.min.y
    tcx = (text_bb.min.x + text_bb.max.x) / 2.0
    tcy = (text_bb.min.y + text_bb.max.y) / 2.0

    bz = -0.2
    rx = tw / 2.0 + ELEV_LABEL_PAD_X
    rz = th / 2.0 + ELEV_LABEL_PAD_Z
    ptr_h = ELEV_POINTER_HEIGHT
    ptr_w = ptr_h * 0.8

    # Rectangle + pointer triangle — callout bubble shape (7-point polygon)
    bg_pts = [
      Geom::Point3d.new(tcx - rx, tcy + rz, bz),      # top-left
      Geom::Point3d.new(tcx + rx, tcy + rz, bz),      # top-right
      Geom::Point3d.new(tcx + rx, tcy - rz, bz),      # bottom-right
      Geom::Point3d.new(tcx + ptr_w, tcy - rz, bz),   # pointer right
      Geom::Point3d.new(tcx, tcy - rz - ptr_h, bz),   # pointer tip
      Geom::Point3d.new(tcx - ptr_w, tcy - rz, bz),   # pointer left
      Geom::Point3d.new(tcx - rx, tcy - rz, bz)       # bottom-left
    ]
    rect_face = ents.add_face(bg_pts)
    bg_faces = [rect_face].compact

    # Outline — same callout shape, slightly larger
    outline_z = -0.4
    orx = rx + ELEV_OUTLINE_WIDTH
    orz = rz + ELEV_OUTLINE_WIDTH
    optr_w = ptr_w + ELEV_OUTLINE_WIDTH
    optr_h = ptr_h + ELEV_OUTLINE_WIDTH
    outline_pts = [
      Geom::Point3d.new(tcx - orx, tcy + orz, outline_z),
      Geom::Point3d.new(tcx + orx, tcy + orz, outline_z),
      Geom::Point3d.new(tcx + orx, tcy - orz, outline_z),
      Geom::Point3d.new(tcx + optr_w, tcy - orz, outline_z),
      Geom::Point3d.new(tcx, tcy - orz - optr_h, outline_z),
      Geom::Point3d.new(tcx - optr_w, tcy - orz, outline_z),
      Geom::Point3d.new(tcx - orx, tcy - orz, outline_z)
    ]
    outline_face = ents.add_face(outline_pts) rescue nil
    bg_faces << outline_face if outline_face

    if rect_face
      rect_face.material = mat; rect_face.back_material = mat
    end
    if outline_face
      outline_face.material = border_mat; outline_face.back_material = border_mat
    end

    ents.grep(Sketchup::Face).each do |f|
      next if bg_faces.include?(f)
      f.material = text_mat; f.back_material = text_mat
    end

    # NOTE: no upright rotation here — orientation is handled in create_elev_label
  end

  def self.activate_benchmark_tool
    Sketchup.active_model.select_tool(BenchmarkTool.new)
  end

  def self.activate_elevation_tool
    Sketchup.active_model.select_tool(ElevationTagTool.new)
  end
end
