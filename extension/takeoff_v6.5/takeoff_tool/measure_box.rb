module TakeoffTool
  unless defined?(BOX_DEFAULT_COLOR)
  BOX_DEFAULT_COLOR = [180, 130, 250, 120]  # Catppuccin mauve-ish
  BOX_EDGE_COLOR    = [203, 166, 247]       # #cba6f7
  BOX_FILL_ALPHA    = 40
  BOX_CUTOUT_COLOR  = [243, 139, 168]       # #f38ba8 red
  end # unless defined?(BOX_DEFAULT_COLOR)

  class MeasureBoxTool

    def initialize(preset_category = nil)
      @state = 0          # 0=pick_corner1, 1=pick_corner2, 2=pick_height, 3=placed
      @pt1 = nil          # First corner (Geom::Point3d)
      @pt2 = nil          # Opposite base corner
      @base_z = 0.0       # Z elevation of base plane
      @width = 0.0        # inches (X extent)
      @depth = 0.0        # inches (Y extent)
      @height = 0.0       # inches (Z extent, can be negative)
      @mouse_pt = nil
      @ip = Sketchup::InputPoint.new
      @ip_start = Sketchup::InputPoint.new
      @preset_category = preset_category
      @last_cat = nil
      @last_cc = ''
      @last_note = ''
      @panel = nil
      @cutouts = []       # [{face:, u1:, v1:, u2:, v2:, width_in:, height_in:, area_sf:}]
      @cutout_mode = false
      @cutout_face_idx = nil
      @cutout_pt1 = nil
      @cutout_mouse = nil
      @category_detected = false

      @save_pending = false
    end

    # ═══════════════════════════════════════════════════════════════
    # TOOL LIFECYCLE
    # ═══════════════════════════════════════════════════════════════

    def activate
      reset_full
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

    # ═══════════════════════════════════════════════════════════════
    # MOUSE
    # ═══════════════════════════════════════════════════════════════

    def onMouseMove(flags, x, y, view)
      return if @save_pending
      # Cutout drag
      if @cutout_mode && @cutout_pt1
        @cutout_mouse = project_to_box_face(x, y, view, @cutout_face_idx)
        view.invalidate
        return
      end

      @ip.pick(view, x, y, @state >= 1 ? @ip_start : nil)
      return unless @ip.valid?

      case @state
      when 0
        @mouse_pt = @ip.position
        view.tooltip = @ip.tooltip
      when 1
        pt = @ip.position
        @mouse_pt = Geom::Point3d.new(pt.x, pt.y, @base_z)
        compute_dimensions_from(@pt1, @mouse_pt)
      when 2
        # Constrain to vertical axis through the midpoint of the base
        ray = view.pickray(x, y)
        # Project mouse onto vertical line at pt2
        anchor = @pt2.clone
        z_axis = Geom::Vector3d.new(0, 0, 1)
        closest = closest_point_on_line(ray, [anchor, z_axis])
        @height = closest.z - @base_z
        @mouse_pt = Geom::Point3d.new(@pt2.x, @pt2.y, closest.z)
      end

      update_panel if @state > 0
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return if @save_pending
      # Cutout clicks
      if @cutout_mode
        handle_cutout_click(x, y, view)
        return
      end

      @ip.pick(view, x, y, @state >= 1 ? @ip_start : nil)
      return unless @ip.valid?

      case @state
      when 0
        # Auto-detect category on first click
        unless @category_detected
          cat = detect_category_at(x, y, view)
          if cat
            @last_cat = cat
            set_panel_category(cat)
          end
          @category_detected = true
        end

        @pt1 = @ip.position.clone
        @base_z = @pt1.z
        @ip_start.copy!(@ip)
        @state = 1
        update_status

      when 1
        pt = @ip.position
        @pt2 = Geom::Point3d.new(pt.x, pt.y, @base_z)
        compute_dimensions_from(@pt1, @pt2)
        return if @width < 0.1 || @depth < 0.1  # Require some area
        @state = 2
        update_status

      when 2
        return if @height.abs < 0.1  # Require some height
        @state = 3
        update_panel
        update_status
      end

      view.invalidate
    end

    def onLButtonDoubleClick(flags, x, y, view)
      trigger_save if @state == 3
    end

    def onKeyDown(key, repeat, flags, view)
      case key
      when 13  # Enter
        trigger_save if @state == 3
      when 8   # Backspace — step back
        step_back(view)
      end
    end

    def onCancel(reason, view)
      if @cutout_mode
        exit_cutout_mode
        view.invalidate
      elsif @state > 0
        step_back(view)
      else
        Sketchup.active_model.select_tool(nil)
      end
    end

    def getMenu(menu, flags, x, y, view)
      if @state == 3
        menu.add_item('Save Measurement') { trigger_save }
        menu.add_item('Add Cutout') { enter_cutout_mode }
        menu.add_item('Reset Box') { reset_full; update_panel; view.invalidate }
      end
      menu.add_separator
      menu.add_item('Exit Box Tool') { Sketchup.active_model.select_tool(nil) }
    end

    # ═══════════════════════════════════════════════════════════════
    # DRAW
    # ═══════════════════════════════════════════════════════════════

    def draw(view)
      case @state
      when 0
        draw_cursor_label(view)
      when 1
        draw_base_rectangle(view)
      when 2
        draw_box_wireframe(view, true)
      when 3
        draw_box_wireframe(view, false)
        draw_cutout_overlays(view)
        draw_cutout_preview(view) if @cutout_mode && @cutout_pt1 && @cutout_mouse
      end
    end

    def getExtents
      bb = Geom::BoundingBox.new
      if @pt1
        bb.add(@pt1)
        bb.add(@pt2) if @pt2
        corners = box_corners
        corners.each { |c| bb.add(c) } if corners
      end
      bb
    end

    private

    # ═══════════════════════════════════════════════════════════════
    # STATE HELPERS
    # ═══════════════════════════════════════════════════════════════

    def step_back(view)
      case @state
      when 3
        @state = 2
        @cutouts.clear
        exit_cutout_mode if @cutout_mode
      when 2
        @state = 1
        @height = 0.0
      when 1
        @state = 0
        @pt1 = nil
        @pt2 = nil
        @width = 0.0
        @depth = 0.0
      when 0
        Sketchup.active_model.select_tool(nil)
        return
      end
      update_panel
      update_status
      view.invalidate
    end

    def reset_full
      @state = 0
      @pt1 = nil
      @pt2 = nil
      @mouse_pt = nil
      @base_z = 0.0
      @width = 0.0
      @depth = 0.0
      @height = 0.0
      @cutouts = []
      @cutout_mode = false
      @cutout_face_idx = nil
      @cutout_pt1 = nil
      @cutout_mouse = nil
      @category_detected = false
      @ip = Sketchup::InputPoint.new
      @ip_start = Sketchup::InputPoint.new
    end

    def compute_dimensions_from(a, b)
      @width = (b.x - a.x).abs
      @depth = (b.y - a.y).abs
    end

    def compute_areas
      w = @width       # inches
      d = @depth
      h = @height.abs
      wall_sf = 2.0 * (w * h + d * h) / 144.0
      floor_sf = (w * d) / 144.0
      ceiling_sf = floor_sf
      total_sf = wall_sf + floor_sf + ceiling_sf
      volume_cf = (w * d * h) / 1728.0
      perimeter_lf = 2.0 * (w + d) / 12.0
      cutout_sf = @cutouts.reduce(0.0) { |s, c| s + (c[:area_sf] || 0.0) }
      net_wall_sf = [wall_sf - cutout_sf, 0.0].max
      {
        wall_sf: wall_sf, floor_sf: floor_sf, ceiling_sf: ceiling_sf,
        total_sf: total_sf, volume_cf: volume_cf, perimeter_lf: perimeter_lf,
        cutout_sf: cutout_sf, net_wall_sf: net_wall_sf
      }
    end

    # ═══════════════════════════════════════════════════════════════
    # BOX GEOMETRY
    # ═══════════════════════════════════════════════════════════════

    def box_corners
      return nil unless @pt1 && (@pt2 || @mouse_pt)
      p2 = @pt2 || @mouse_pt
      x0 = [@pt1.x, p2.x].min
      y0 = [@pt1.y, p2.y].min
      x1 = [@pt1.x, p2.x].max
      y1 = [@pt1.y, p2.y].max
      z0 = @base_z
      z1 = @base_z + @height
      if z0 > z1
        z0, z1 = z1, z0
      end
      [
        Geom::Point3d.new(x0, y0, z0),  # 0: bottom-front-left
        Geom::Point3d.new(x1, y0, z0),  # 1: bottom-front-right
        Geom::Point3d.new(x1, y1, z0),  # 2: bottom-back-right
        Geom::Point3d.new(x0, y1, z0),  # 3: bottom-back-left
        Geom::Point3d.new(x0, y0, z1),  # 4: top-front-left
        Geom::Point3d.new(x1, y0, z1),  # 5: top-front-right
        Geom::Point3d.new(x1, y1, z1),  # 6: top-back-right
        Geom::Point3d.new(x0, y1, z1),  # 7: top-back-left
      ]
    end

    # 6 face quads as arrays of 4 corner indices
    BOX_FACE_INDICES = [
      [0, 1, 2, 3],  # bottom
      [4, 5, 6, 7],  # top
      [0, 1, 5, 4],  # front (Y-min)
      [2, 3, 7, 6],  # back  (Y-max)
      [0, 3, 7, 4],  # left  (X-min)
      [1, 2, 6, 5],  # right (X-max)
    ]

    BOX_FACE_NAMES = [:bottom, :top, :front, :back, :left, :right]

    # 12 edge pairs as index pairs
    BOX_EDGE_INDICES = [
      [0,1],[1,2],[2,3],[3,0],  # bottom
      [4,5],[5,6],[6,7],[7,4],  # top
      [0,4],[1,5],[2,6],[3,7],  # verticals
    ]

    # ═══════════════════════════════════════════════════════════════
    # DRAWING HELPERS
    # ═══════════════════════════════════════════════════════════════

    def draw_cursor_label(view)
      @ip.draw(view) if @ip.valid?
      return unless @mouse_pt
      screen = view.screen_coords(@mouse_pt)
      txt_pt = Geom::Point3d.new(screen.x + 14, screen.y - 14, 0)
      view.draw_text(txt_pt, "BOX", color: Sketchup::Color.new(*BOX_EDGE_COLOR))
    end

    def draw_base_rectangle(view)
      @ip.draw(view) if @ip.valid?
      return unless @pt1 && @mouse_pt

      p2 = @mouse_pt
      x0 = [@pt1.x, p2.x].min
      y0 = [@pt1.y, p2.y].min
      x1 = [@pt1.x, p2.x].max
      y1 = [@pt1.y, p2.y].max
      z = @base_z

      pts = [
        Geom::Point3d.new(x0, y0, z),
        Geom::Point3d.new(x1, y0, z),
        Geom::Point3d.new(x1, y1, z),
        Geom::Point3d.new(x0, y1, z),
      ]

      # Fill
      view.drawing_color = Sketchup::Color.new(BOX_EDGE_COLOR[0], BOX_EDGE_COLOR[1], BOX_EDGE_COLOR[2], BOX_FILL_ALPHA)
      view.draw(GL_POLYGON, pts)

      # Outline
      view.line_width = 2
      view.line_stipple = ''
      view.drawing_color = Sketchup::Color.new(*BOX_EDGE_COLOR)
      view.draw(GL_LINE_LOOP, pts)

      # Dimension labels
      draw_dim_label(view, pts[0], pts[1], format_length(@width), [0, 0, -1])
      draw_dim_label(view, pts[1], pts[2], format_length(@depth), [1, 0, 0])
    end

    def draw_box_wireframe(view, height_preview)
      corners = box_corners
      return unless corners

      # If in state 2 (height preview), use mouse position for height
      if height_preview && @mouse_pt
        z1 = @mouse_pt.z
        z0 = @base_z
        if z0 > z1
          z0, z1 = z1, z0
        end
        x0 = corners[0].x
        y0 = corners[0].y
        x1 = corners[1].x
        y1 = corners[2].y
        corners = [
          Geom::Point3d.new(x0, y0, z0),
          Geom::Point3d.new(x1, y0, z0),
          Geom::Point3d.new(x1, y1, z0),
          Geom::Point3d.new(x0, y1, z0),
          Geom::Point3d.new(x0, y0, z1),
          Geom::Point3d.new(x1, y0, z1),
          Geom::Point3d.new(x1, y1, z1),
          Geom::Point3d.new(x0, y1, z1),
        ]
      end

      # Fill faces with semi-transparent color
      view.drawing_color = Sketchup::Color.new(BOX_EDGE_COLOR[0], BOX_EDGE_COLOR[1], BOX_EDGE_COLOR[2], BOX_FILL_ALPHA)
      BOX_FACE_INDICES.each do |fi|
        face_pts = fi.map { |i| corners[i] }
        view.draw(GL_POLYGON, face_pts)
      end

      # Edge lines
      view.line_width = 2
      view.line_stipple = height_preview ? '_' : ''
      view.drawing_color = Sketchup::Color.new(*BOX_EDGE_COLOR)

      BOX_EDGE_INDICES.each do |a, b|
        view.draw(GL_LINES, [corners[a], corners[b]])
      end

      # Bottom edges solid even during height preview
      if height_preview
        view.line_stipple = ''
        view.drawing_color = Sketchup::Color.new(*BOX_EDGE_COLOR)
        [[0,1],[1,2],[2,3],[3,0]].each do |a, b|
          view.draw(GL_LINES, [corners[a], corners[b]])
        end
      end

      # Dimension labels
      h = @state == 2 ? (@mouse_pt ? (@mouse_pt.z - @base_z).abs : @height.abs) : @height.abs
      draw_dim_label(view, corners[0], corners[1], format_length(@width), [0, -1, 0])
      draw_dim_label(view, corners[1], corners[2], format_length(@depth), [1, 0, 0])
      draw_dim_label(view, corners[0], corners[4], format_length(h), [-1, 0, 0]) if h > 0.1
    end

    def draw_dim_label(view, pt_a, pt_b, text, offset_hint)
      mid = Geom::Point3d.new(
        (pt_a.x + pt_b.x) / 2.0,
        (pt_a.y + pt_b.y) / 2.0,
        (pt_a.z + pt_b.z) / 2.0
      )
      screen = view.screen_coords(mid)
      ox = offset_hint[0] * 20
      oy = offset_hint[1] * 20 - 8
      txt_pt = Geom::Point3d.new(screen.x + ox, screen.y + oy, 0)
      view.draw_text(txt_pt, text, color: Sketchup::Color.new(166, 227, 161))  # #a6e3a1 green
    end

    # ═══════════════════════════════════════════════════════════════
    # CUTOUT MODE
    # ═══════════════════════════════════════════════════════════════

    def enter_cutout_mode
      return unless @state == 3
      @cutout_mode = true
      @cutout_face_idx = nil
      @cutout_pt1 = nil
      @cutout_mouse = nil
      Sketchup.status_text = "Cutout: Click first corner on a box face. ESC to cancel."
    end

    def exit_cutout_mode
      @cutout_mode = false
      @cutout_face_idx = nil
      @cutout_pt1 = nil
      @cutout_mouse = nil
      update_status
    end

    def handle_cutout_click(x, y, view)
      hit = hit_test_box_face(x, y, view)
      unless hit
        Sketchup.status_text = "Cutout: Click on a box face."
        return
      end

      if @cutout_pt1.nil?
        # First corner
        @cutout_face_idx = hit[:face_idx]
        @cutout_pt1 = hit
        Sketchup.status_text = "Cutout: Click second corner on the #{BOX_FACE_NAMES[@cutout_face_idx]} face. ESC to cancel."
      else
        # Second corner — must be on same face
        if hit[:face_idx] != @cutout_face_idx
          Sketchup.status_text = "Cutout: Second corner must be on the same face (#{BOX_FACE_NAMES[@cutout_face_idx]})."
          return
        end
        add_cutout(@cutout_face_idx, @cutout_pt1[:u], @cutout_pt1[:v], hit[:u], hit[:v])
        exit_cutout_mode
        update_panel
        view.invalidate
      end
    end

    def add_cutout(face_idx, u1, v1, u2, v2)
      # Normalize so u1<u2, v1<v2
      u1, u2 = [u1, u2].min, [u1, u2].max
      v1, v2 = [v1, v2].min, [v1, v2].max

      face_name = BOX_FACE_NAMES[face_idx]
      # Calculate actual dimensions based on which face
      case face_name
      when :front, :back
        w_in = (u2 - u1) * @width
        h_in = (v2 - v1) * @height.abs
      when :left, :right
        w_in = (u2 - u1) * @depth
        h_in = (v2 - v1) * @height.abs
      when :top, :bottom
        w_in = (u2 - u1) * @width
        h_in = (v2 - v1) * @depth
      end

      area_sf = (w_in * h_in) / 144.0

      @cutouts << {
        face: face_name,
        face_idx: face_idx,
        u1: u1, v1: v1, u2: u2, v2: v2,
        width_in: w_in, height_in: h_in,
        area_sf: area_sf
      }
    end

    def remove_cutout(index)
      @cutouts.delete_at(index.to_i) if index.to_i < @cutouts.length
    end

    def hit_test_box_face(x, y, view)
      corners = box_corners
      return nil unless corners

      ray_origin, ray_dir = view.pickray(x, y)
      best_hit = nil
      best_dist = Float::INFINITY

      BOX_FACE_INDICES.each_with_index do |fi, face_idx|
        face_pts = fi.map { |i| corners[i] }

        # Compute face normal
        v1 = Geom::Vector3d.new(
          face_pts[1].x - face_pts[0].x,
          face_pts[1].y - face_pts[0].y,
          face_pts[1].z - face_pts[0].z
        )
        v2 = Geom::Vector3d.new(
          face_pts[3].x - face_pts[0].x,
          face_pts[3].y - face_pts[0].y,
          face_pts[3].z - face_pts[0].z
        )
        normal = v1.cross(v2)
        next if normal.length < 0.001
        normal.normalize!

        # Ray-plane intersection
        denom = normal.dot(ray_dir)
        next if denom.abs < 0.0001  # Parallel

        d = normal.x * face_pts[0].x + normal.y * face_pts[0].y + normal.z * face_pts[0].z
        t = (d - (normal.x * ray_origin.x + normal.y * ray_origin.y + normal.z * ray_origin.z)) / denom
        next if t < 0  # Behind camera

        # Intersection point
        hit = Geom::Point3d.new(
          ray_origin.x + ray_dir.x * t,
          ray_origin.y + ray_dir.y * t,
          ray_origin.z + ray_dir.z * t
        )

        # Project hit point into face's local UV (0..1, 0..1)
        # face_pts: [p0, p1, p2, p3] forming a quad
        # U axis = p0→p1, V axis = p0→p3
        u_vec = Geom::Vector3d.new(
          face_pts[1].x - face_pts[0].x,
          face_pts[1].y - face_pts[0].y,
          face_pts[1].z - face_pts[0].z
        )
        v_vec = Geom::Vector3d.new(
          face_pts[3].x - face_pts[0].x,
          face_pts[3].y - face_pts[0].y,
          face_pts[3].z - face_pts[0].z
        )
        u_len = u_vec.length
        v_len = v_vec.length
        next if u_len < 0.001 || v_len < 0.001

        local = Geom::Vector3d.new(
          hit.x - face_pts[0].x,
          hit.y - face_pts[0].y,
          hit.z - face_pts[0].z
        )

        u_norm = Geom::Vector3d.new(u_vec.x / u_len, u_vec.y / u_len, u_vec.z / u_len)
        v_norm = Geom::Vector3d.new(v_vec.x / v_len, v_vec.y / v_len, v_vec.z / v_len)

        u = local.dot(u_norm) / u_len
        v = local.dot(v_norm) / v_len

        # Check bounds with small tolerance
        next unless u >= -0.01 && u <= 1.01 && v >= -0.01 && v <= 1.01
        u = [[u, 0.0].max, 1.0].min
        v = [[v, 0.0].max, 1.0].min

        if t < best_dist
          best_dist = t
          best_hit = { face_idx: face_idx, u: u, v: v, point: hit }
        end
      end

      best_hit
    end

    def project_to_box_face(x, y, view, face_idx)
      # Same as hit_test but only checks the specific face
      corners = box_corners
      return nil unless corners

      fi = BOX_FACE_INDICES[face_idx]
      face_pts = fi.map { |i| corners[i] }

      ray_origin, ray_dir = view.pickray(x, y)

      v1 = Geom::Vector3d.new(
        face_pts[1].x - face_pts[0].x,
        face_pts[1].y - face_pts[0].y,
        face_pts[1].z - face_pts[0].z
      )
      v2 = Geom::Vector3d.new(
        face_pts[3].x - face_pts[0].x,
        face_pts[3].y - face_pts[0].y,
        face_pts[3].z - face_pts[0].z
      )
      normal = v1.cross(v2)
      return nil if normal.length < 0.001
      normal.normalize!

      denom = normal.dot(ray_dir)
      return nil if denom.abs < 0.0001

      d = normal.x * face_pts[0].x + normal.y * face_pts[0].y + normal.z * face_pts[0].z
      t = (d - (normal.x * ray_origin.x + normal.y * ray_origin.y + normal.z * ray_origin.z)) / denom
      return nil if t < 0

      hit = Geom::Point3d.new(
        ray_origin.x + ray_dir.x * t,
        ray_origin.y + ray_dir.y * t,
        ray_origin.z + ray_dir.z * t
      )

      u_vec = v1
      v_vec = v2
      u_len = u_vec.length
      v_len = v_vec.length
      return nil if u_len < 0.001 || v_len < 0.001

      local = Geom::Vector3d.new(hit.x - face_pts[0].x, hit.y - face_pts[0].y, hit.z - face_pts[0].z)
      u_norm = Geom::Vector3d.new(u_vec.x / u_len, u_vec.y / u_len, u_vec.z / u_len)
      v_norm = Geom::Vector3d.new(v_vec.x / v_len, v_vec.y / v_len, v_vec.z / v_len)

      u = [[local.dot(u_norm) / u_len, 0.0].max, 1.0].min
      v = [[local.dot(v_norm) / v_len, 0.0].max, 1.0].min

      { face_idx: face_idx, u: u, v: v, point: hit }
    end

    def cutout_3d_rect(cutout)
      corners = box_corners
      return nil unless corners

      fi = BOX_FACE_INDICES[cutout[:face_idx]]
      p0 = corners[fi[0]]
      p1 = corners[fi[1]]
      p3 = corners[fi[3]]

      u_vec = Geom::Vector3d.new(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z)
      v_vec = Geom::Vector3d.new(p3.x - p0.x, p3.y - p0.y, p3.z - p0.z)

      c1 = Geom::Point3d.new(
        p0.x + u_vec.x * cutout[:u1] + v_vec.x * cutout[:v1],
        p0.y + u_vec.y * cutout[:u1] + v_vec.y * cutout[:v1],
        p0.z + u_vec.z * cutout[:u1] + v_vec.z * cutout[:v1]
      )
      c2 = Geom::Point3d.new(
        p0.x + u_vec.x * cutout[:u2] + v_vec.x * cutout[:v1],
        p0.y + u_vec.y * cutout[:u2] + v_vec.y * cutout[:v1],
        p0.z + u_vec.z * cutout[:u2] + v_vec.z * cutout[:v1]
      )
      c3 = Geom::Point3d.new(
        p0.x + u_vec.x * cutout[:u2] + v_vec.x * cutout[:v2],
        p0.y + u_vec.y * cutout[:u2] + v_vec.y * cutout[:v2],
        p0.z + u_vec.z * cutout[:u2] + v_vec.z * cutout[:v2]
      )
      c4 = Geom::Point3d.new(
        p0.x + u_vec.x * cutout[:u1] + v_vec.x * cutout[:v2],
        p0.y + u_vec.y * cutout[:u1] + v_vec.y * cutout[:v2],
        p0.z + u_vec.z * cutout[:u1] + v_vec.z * cutout[:v2]
      )
      [c1, c2, c3, c4]
    end

    def draw_cutout_overlays(view)
      return if @cutouts.empty?

      view.line_width = 2
      view.drawing_color = Sketchup::Color.new(*BOX_CUTOUT_COLOR)

      @cutouts.each do |cutout|
        rect = cutout_3d_rect(cutout)
        next unless rect
        view.draw(GL_LINE_LOOP, rect)
        # Hatching — draw X across cutout
        view.line_stipple = '-'
        view.draw(GL_LINES, [rect[0], rect[2]])
        view.draw(GL_LINES, [rect[1], rect[3]])
        view.line_stipple = ''
      end
    end

    def draw_cutout_preview(view)
      return unless @cutout_pt1 && @cutout_mouse && @cutout_face_idx

      corners = box_corners
      return unless corners

      fi = BOX_FACE_INDICES[@cutout_face_idx]
      p0 = corners[fi[0]]
      p1 = corners[fi[1]]
      p3 = corners[fi[3]]

      u_vec = Geom::Vector3d.new(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z)
      v_vec = Geom::Vector3d.new(p3.x - p0.x, p3.y - p0.y, p3.z - p0.z)

      u1 = @cutout_pt1[:u]
      v1 = @cutout_pt1[:v]
      u2 = @cutout_mouse[:u]
      v2 = @cutout_mouse[:v]

      pts = [
        Geom::Point3d.new(p0.x + u_vec.x*u1 + v_vec.x*v1, p0.y + u_vec.y*u1 + v_vec.y*v1, p0.z + u_vec.z*u1 + v_vec.z*v1),
        Geom::Point3d.new(p0.x + u_vec.x*u2 + v_vec.x*v1, p0.y + u_vec.y*u2 + v_vec.y*v1, p0.z + u_vec.z*u2 + v_vec.z*v1),
        Geom::Point3d.new(p0.x + u_vec.x*u2 + v_vec.x*v2, p0.y + u_vec.y*u2 + v_vec.y*v2, p0.z + u_vec.z*u2 + v_vec.z*v2),
        Geom::Point3d.new(p0.x + u_vec.x*u1 + v_vec.x*v2, p0.y + u_vec.y*u1 + v_vec.y*v2, p0.z + u_vec.z*u1 + v_vec.z*v2),
      ]

      # Fill with semi-transparent red
      view.drawing_color = Sketchup::Color.new(BOX_CUTOUT_COLOR[0], BOX_CUTOUT_COLOR[1], BOX_CUTOUT_COLOR[2], 50)
      view.draw(GL_POLYGON, pts)

      view.line_width = 2
      view.line_stipple = '-'
      view.drawing_color = Sketchup::Color.new(*BOX_CUTOUT_COLOR)
      view.draw(GL_LINE_LOOP, pts)
      view.line_stipple = ''
    end

    # ═══════════════════════════════════════════════════════════════
    # COMPANION PANEL
    # ═══════════════════════════════════════════════════════════════

    def open_panel
      all_cats = TakeoffTool.master_categories
      default_cat = @preset_category || @last_cat || 'Concrete'
      cat_opts = all_cats.map { |c|
        sel = c == default_cat ? ' selected' : ''
        "<option value=\"#{c}\"#{sel}>#{c}</option>"
      }.join
      cat_opts += '<option value="__custom__">+ Custom...</option>'

      @panel = UI::HtmlDialog.new(
        dialog_title: "Box Measurement",
        width: 280, height: 580,
        left: 80, top: 200,
        style: UI::HtmlDialog::STYLE_UTILITY,
        resizable: false
      )

      box_tool = self

      @panel.add_action_callback('save') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          cc  = data['cc'].to_s
          note = data['note'].to_s
          part_name = data['name'].to_s.strip
          box_tool.send(:save_measurement, cat, cc, note, part_name) unless cat.empty?
        rescue => e
          puts "Takeoff Box: save error: #{e.message}"
        end
      end

      @panel.add_action_callback('cancel') do |_ctx|
        Sketchup.active_model.select_tool(nil)
      end

      @panel.add_action_callback('addCutout') do |_ctx|
        box_tool.send(:enter_cutout_mode)
      end

      @panel.add_action_callback('removeCutout') do |_ctx, idx_str|
        box_tool.send(:remove_cutout, idx_str.to_i)
        box_tool.send(:update_panel)
        Sketchup.active_model.active_view.invalidate
      end

      @panel.add_action_callback('resetBox') do |_ctx|
        box_tool.send(:reset_full)
        box_tool.send(:update_panel)
        Sketchup.active_model.active_view.invalidate
      end

      @panel.set_on_closed do
        @panel = nil
        UI.start_timer(0) { Sketchup.active_model.select_tool(nil) }
      end

      @panel.set_html(box_panel_html(cat_opts))
      @panel.show
    end

    def close_panel
      return unless @panel
      p = @panel
      @panel = nil
      begin; p.set_on_closed {}; p.close; rescue; end
    end

    def update_panel
      return unless @panel
      require 'json'

      areas = compute_areas
      h = @state == 2 ? (@mouse_pt ? (@mouse_pt.z - @base_z).abs : @height.abs) : @height.abs
      w_str = format_length(@width)
      d_str = format_length(@depth)
      h_str = format_length(h)

      # Send dimensions and areas
      @panel.execute_script(
        "updateDims(#{JSON.generate(w_str)},#{JSON.generate(d_str)},#{JSON.generate(h_str)}," \
        "#{'%.1f' % areas[:wall_sf]},#{'%.1f' % areas[:floor_sf]}," \
        "#{'%.1f' % areas[:total_sf]},#{'%.1f' % areas[:volume_cf]}," \
        "#{JSON.generate(format_length(areas[:perimeter_lf] * 12))})"
      ) rescue nil

      # Send cutouts
      cutout_data = @cutouts.map.with_index { |c, i|
        { idx: i, face: c[:face].to_s, w: format_length(c[:width_in]), h: format_length(c[:height_in]), sf: ('%.1f' % c[:area_sf]) }
      }
      @panel.execute_script("updateCutouts(#{JSON.generate(cutout_data)},#{'%.1f' % areas[:net_wall_sf]})") rescue nil

      # Enable/disable buttons
      @panel.execute_script("enableSave(#{@state == 3})") rescue nil
      @panel.execute_script("enableCutout(#{@state == 3})") rescue nil
    end

    def trigger_save
      return unless @panel && @state == 3
      @save_pending = true
      @panel.bring_to_front rescue nil
      @panel.execute_script("focusName()") rescue nil
    end

    def box_panel_html(cat_options)
      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font:13px/1.4 'Segoe UI',system-ui,sans-serif;background:#1e1e2e;color:#cdd6f4;padding:14px;overflow-y:auto;overflow-x:hidden}
        .hdr{font-size:11px;font-weight:700;color:#cba6f7;text-transform:uppercase;letter-spacing:1px;text-align:center;margin-bottom:4px}
        .dims{font-size:22px;font-weight:700;color:#a6e3a1;text-align:center;margin:4px 0 2px;word-spacing:2px}
        .dims-label{font-size:10px;color:#6c7086;text-align:center;margin-bottom:8px}
        .divider{height:1px;background:#313244;margin:8px -14px}
        .row{display:flex;justify-content:space-between;padding:3px 0;font-size:12px}
        .row .lbl{color:#a6adc8}
        .row .val{color:#cdd6f4;font-weight:600}
        .section-hdr{display:flex;justify-content:space-between;align-items:center;margin-top:8px;margin-bottom:4px}
        .section-hdr span{font-size:11px;font-weight:700;color:#f38ba8;text-transform:uppercase;letter-spacing:0.5px}
        .co-btn{background:#45475a;color:#f38ba8;border:none;border-radius:4px;padding:3px 8px;font-size:11px;font-weight:600;cursor:pointer}
        .co-btn:hover:not(:disabled){background:#585b70}
        .co-btn:disabled{opacity:0.3;cursor:default}
        .co-list{max-height:80px;overflow-y:auto;margin-bottom:4px}
        .co-item{display:flex;justify-content:space-between;align-items:center;padding:2px 4px;font-size:11px;background:#313244;border-radius:3px;margin-bottom:2px}
        .co-item .co-del{color:#f38ba8;cursor:pointer;font-weight:700;padding:0 4px}
        .co-item .co-del:hover{color:#eba0ac}
        .net-row{display:flex;justify-content:space-between;padding:4px 0;font-size:12px;font-weight:700}
        .net-row .lbl{color:#f38ba8}
        .net-row .val{color:#f38ba8}
        label{display:block;color:#a6adc8;font-size:11px;margin-bottom:3px;margin-top:8px;font-weight:600;text-transform:uppercase;letter-spacing:0.5px}
        select,input[type=text]{width:100%;padding:7px 9px;background:#313244;color:#cdd6f4;border:1px solid #585b70;border-radius:5px;font-size:12px;font-family:inherit}
        select:focus,input:focus{outline:none;border-color:#89b4fa}
        .btns{display:flex;gap:8px;margin-top:14px}
        .btn{flex:1;padding:8px 0;border:none;border-radius:5px;font-size:12px;font-weight:600;cursor:pointer;font-family:inherit;text-align:center}
        .btn-save{background:#a6e3a1;color:#1e1e2e}
        .btn-save:hover:not(:disabled){background:#8cd68c}
        .btn-save:disabled{opacity:0.4;cursor:default}
        .btn-cancel{background:#45475a;color:#cdd6f4}
        .btn-cancel:hover{background:#585b70}
        #customRow{display:none;margin-top:6px}
        #customRow.show{display:block}
        </style></head><body>
        <div class="hdr">Box Measurement</div>
        <div class="dims" id="dimsVal">0'-0" x 0'-0" x 0'-0"</div>
        <div class="dims-label">Width x Depth x Height</div>
        <div class="divider"></div>
        <div class="row"><span class="lbl">Wall SF</span><span class="val" id="wallSF">0.0</span></div>
        <div class="row"><span class="lbl">Floor SF</span><span class="val" id="floorSF">0.0</span></div>
        <div class="row"><span class="lbl">Total SF</span><span class="val" id="totalSF">0.0</span></div>
        <div class="row"><span class="lbl">Volume</span><span class="val" id="volCF">0.0 CF</span></div>
        <div class="row"><span class="lbl">Perimeter</span><span class="val" id="perimLF">0'-0"</span></div>
        <div class="divider"></div>
        <div class="section-hdr">
          <span>Cutouts (<span id="coCnt">0</span>)</span>
          <button class="co-btn" id="coBtn" onclick="sketchup.addCutout()" disabled>+ Add</button>
        </div>
        <div class="co-list" id="coList"></div>
        <div class="net-row"><span class="lbl">Net Wall SF</span><span class="val" id="netSF">0.0</span></div>
        <div class="divider"></div>
        <label>Name</label>
        <input id="name" type="text" placeholder="e.g. Garage Slab, Foundation Wall...">
        <label>Category</label>
        <select id="cat" onchange="onCatChange()">#{cat_options}</select>
        <div id="customRow"><input id="customName" type="text" placeholder="New category name..."></div>
        <label>Cost Code</label>
        <input id="cc" type="text" placeholder="Optional">
        <label>Note</label>
        <input id="note" type="text" placeholder="Optional">
        <div class="btns">
          <button class="btn btn-cancel" onclick="doCancel()">Cancel</button>
          <button class="btn btn-save" id="saveBtn" onclick="doSave()" disabled>Save</button>
        </div>
        <script>
        function updateDims(w,d,h,wallSF,floorSF,totalSF,volCF,perimLF){
          document.getElementById('dimsVal').textContent=w+' \\u00d7 '+d+' \\u00d7 '+h;
          document.getElementById('wallSF').textContent=wallSF;
          document.getElementById('floorSF').textContent=floorSF;
          document.getElementById('totalSF').textContent=totalSF;
          document.getElementById('volCF').textContent=volCF+' CF';
          document.getElementById('perimLF').textContent=perimLF;
        }
        function updateCutouts(list,netSF){
          var el=document.getElementById('coList');
          document.getElementById('coCnt').textContent=list.length;
          document.getElementById('netSF').textContent=netSF;
          if(!list.length){el.innerHTML='';return;}
          var h='';
          for(var i=0;i<list.length;i++){
            var c=list[i];
            h+='<div class="co-item"><span>'+c.face+': '+c.w+' \\u00d7 '+c.h+' (-'+c.sf+' SF)</span><span class="co-del" onclick="sketchup.removeCutout(\''+c.idx+'\')">\\u00d7</span></div>';
          }
          el.innerHTML=h;
        }
        function enableSave(b){document.getElementById('saveBtn').disabled=!b;}
        function enableCutout(b){document.getElementById('coBtn').disabled=!b;}
        function onCatChange(){document.getElementById('customRow').className=document.getElementById('cat').value==='__custom__'?'show':'';}
        function doSave(){
          var cat=document.getElementById('cat').value;
          if(cat==='__custom__'){cat=document.getElementById('customName').value.trim();if(!cat)return;}
          if(document.getElementById('saveBtn').disabled)return;
          sketchup.save(JSON.stringify({cat:cat,name:document.getElementById('name').value.trim(),cc:document.getElementById('cc').value,note:document.getElementById('note').value}));
        }
        function doCancel(){sketchup.cancel();}
        function focusName(){document.getElementById('name').focus();}
        function setCategory(cat){var sel=document.getElementById('cat');for(var i=0;i<sel.options.length;i++){if(sel.options[i].value===cat){sel.selectedIndex=i;onCatChange();return;}}}
        document.addEventListener('keydown',function(e){if(e.key==='Escape')doCancel();});
        </script>
        </body></html>
      HTML
    end

    # ═══════════════════════════════════════════════════════════════
    # CATEGORY DETECTION
    # ═══════════════════════════════════════════════════════════════

    def detect_category_at(x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      path = ph.path_at(0)
      return nil unless path
      assignments = TakeoffTool.category_assignments
      path.each do |ent|
        next unless ent.respond_to?(:entityID)
        cat = assignments[ent.entityID]
        return cat if cat
      end
      nil
    end

    def set_panel_category(cat)
      return unless @panel
      require 'json'
      @panel.execute_script("setCategory(#{JSON.generate(cat)})") rescue nil
    end

    # ═══════════════════════════════════════════════════════════════
    # SAVE
    # ═══════════════════════════════════════════════════════════════

    def save_measurement(cat, cc, note, part_name = '')
      return unless @state == 3

      TakeoffTool.add_custom_category(cat) unless TakeoffTool.master_categories.include?(cat)
      @last_cat = cat
      @last_cc = cc
      @last_note = note
      @last_part_name = part_name

      # Set category measurement type to CF if not already set
      m = Sketchup.active_model
      existing_mt = m.get_attribute('TakeoffMeasurementTypes', cat) rescue nil
      m.set_attribute('TakeoffMeasurementTypes', cat, 'cf') if !existing_mt || existing_mt.empty?

      grp = create_box_artifact(cat)
      add_to_results(cat, grp)

      Sketchup.status_text = "Box Tool: Saved #{format_dims} of #{cat}. Click to start new box."
      reset_full
      update_panel
      Sketchup.active_model.active_view.invalidate
    end

    def create_box_artifact(cat)
      model = Sketchup.active_model
      model.start_operation('Box Measurement', true)

      tag = model.layers[LF_TAG] || model.layers.add(LF_TAG)

      grp = model.active_entities.add_group
      grp.layer = tag
      pn = @last_part_name && !@last_part_name.empty? ? @last_part_name : nil
      grp.name = pn ? "TO_BOX: #{pn} — #{cat} — #{format_dims}" : "TO_BOX: #{cat} — #{format_dims}"

      # Material — reuse SF colors if available, else default
      rgba = SF_COLORS[cat] || BOX_DEFAULT_COLOR
      rgba = [rgba[0], rgba[1], rgba[2], 120]  # Override alpha for box
      mat_name = "TO_BOX_#{cat.gsub(/[\s\/]+/, '_')}"
      mat = model.materials[mat_name]
      unless mat
        mat = model.materials.add(mat_name)
        mat.color = Sketchup::Color.new(rgba[0], rgba[1], rgba[2])
        mat.alpha = rgba[3] / 255.0
      end

      # Build 6 faces
      corners = box_corners
      BOX_FACE_INDICES.each do |fi|
        face_pts = fi.map { |i| corners[i] }
        begin
          f = grp.entities.add_face(face_pts)
          if f
            f.material = mat
            f.back_material = mat
          end
        rescue => e
          puts "Takeoff Box: face failed: #{e.message}"
        end
      end

      # Store attributes
      areas = compute_areas
      require 'json'

      grp.set_attribute('TakeoffMeasurement', 'type', 'BOX')
      grp.set_attribute('TakeoffMeasurement', 'category', cat)
      grp.set_attribute('TakeoffMeasurement', 'width_in', @width)
      grp.set_attribute('TakeoffMeasurement', 'depth_in', @depth)
      grp.set_attribute('TakeoffMeasurement', 'height_in', @height.abs)
      grp.set_attribute('TakeoffMeasurement', 'wall_sf', areas[:wall_sf])
      grp.set_attribute('TakeoffMeasurement', 'floor_sf', areas[:floor_sf])
      grp.set_attribute('TakeoffMeasurement', 'total_sf', areas[:total_sf])
      grp.set_attribute('TakeoffMeasurement', 'net_wall_sf', areas[:net_wall_sf])
      grp.set_attribute('TakeoffMeasurement', 'volume_cf', areas[:volume_cf])
      grp.set_attribute('TakeoffMeasurement', 'perimeter_lf', areas[:perimeter_lf])
      grp.set_attribute('TakeoffMeasurement', 'cutouts', JSON.generate(@cutouts.map { |c|
        { face: c[:face].to_s, u1: c[:u1], v1: c[:v1], u2: c[:u2], v2: c[:v2],
          width_in: c[:width_in], height_in: c[:height_in], area_sf: c[:area_sf] }
      }))
      grp.set_attribute('TakeoffMeasurement', 'part_name', @last_part_name || '')
      grp.set_attribute('TakeoffMeasurement', 'cost_code', @last_cc || '')
      grp.set_attribute('TakeoffMeasurement', 'note', @last_note || '')
      grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
      grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      grp.set_attribute('TakeoffMeasurement', 'material_name', mat_name)
      grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate(rgba))

      TakeoffTool.entity_registry[grp.entityID] = grp

      model.commit_operation
      @last_grp_eid = grp.entityID
      grp
    end

    def add_to_results(cat, grp)
      areas = compute_areas
      eid = grp.entityID
      pn = @last_part_name && !@last_part_name.empty? ? @last_part_name : nil
      display = pn ? "#{pn} — #{cat} — #{'%.1f' % areas[:volume_cf]} CF" : "#{cat} — #{format_dims} #{'%.1f' % areas[:volume_cf]} CF"

      result = {
        entity_id: eid,
        tag: LF_TAG,
        definition_name: display,
        display_name: display,
        material: '',
        is_solid: true,
        instance_count: 1,
        volume_ft3: areas[:volume_cf],
        volume_bf: 0.0,
        area_sf: areas[:total_sf],
        linear_ft: areas[:perimeter_lf],
        bb_width_in: @width, bb_height_in: @height.abs, bb_depth_in: @depth,
        ifc_type: nil,
        warnings: [],
        parsed: {
          auto_category: cat,
          auto_subcategory: pn || '',
          element_type: cat,
          function: 'BOX',
          material: @last_note || '',
          thickness: '',
          size_nominal: '',
          revit_id: nil
        },
        source: :manual_box
      }

      TakeoffTool.scan_results << result
      TakeoffTool.category_assignments[eid] = cat
      if @last_cc && !@last_cc.empty?
        TakeoffTool.cost_code_assignments[eid] = @last_cc
      end

      d = Dashboard.instance_variable_get(:@dialog)
      if d && d.visible?
        Dashboard.send_data(TakeoffTool.scan_results, TakeoffTool.category_assignments, TakeoffTool.cost_code_assignments)
      end

      puts "Takeoff Box: Added #{cat} #{format_dims} #{'%.1f' % areas[:volume_cf]} CF (entity #{eid})"
    end

    # ═══════════════════════════════════════════════════════════════
    # FORMATTING HELPERS
    # ═══════════════════════════════════════════════════════════════

    def format_length(inches)
      return "0'-0\"" if inches.nil? || inches.abs < 0.001
      inches = inches.abs
      ft = (inches / 12.0).floor
      ins = inches - (ft * 12)
      if ins < 0.0625
        "#{ft}'-0\""
      else
        whole = ins.floor
        frac = ins - whole
        frac_str = fraction_string(frac)
        if frac_str.empty?
          "#{ft}'-#{whole}\""
        else
          "#{ft}'-#{whole} #{frac_str}\""
        end
      end
    end

    def fraction_string(frac)
      return '' if frac < 0.03125
      sixteenths = (frac * 16).round
      return '' if sixteenths == 0 || sixteenths >= 16
      n = sixteenths; d = 16
      while n.even? && d > 1; n /= 2; d /= 2; end
      "#{n}/#{d}"
    end

    def format_dims
      "#{format_length(@width)} x #{format_length(@depth)} x #{format_length(@height.abs)}"
    end

    def update_status
      case @state
      when 0
        Sketchup.status_text = "Box Tool: Click to set first corner. ESC to exit."
      when 1
        Sketchup.status_text = "Box Tool: Click to set opposite corner. Backspace to undo."
      when 2
        Sketchup.status_text = "Box Tool: Move up/down and click to set height. Backspace to undo."
      when 3
        Sketchup.status_text = "Box Tool: #{format_dims} — Enter/Dbl-click to save. Right-click for options."
      end
    end

    def update_vcb
      Sketchup.vcb_label = "Box"
      Sketchup.vcb_value = format_dims
    end

    # Ray-line closest point helper for height picking
    def closest_point_on_line(ray, line)
      ray_pt, ray_dir = ray
      line_pt, line_dir = line

      # Find point on line closest to ray
      w = Geom::Vector3d.new(
        ray_pt.x - line_pt.x,
        ray_pt.y - line_pt.y,
        ray_pt.z - line_pt.z
      )

      a = ray_dir.dot(ray_dir)
      b = ray_dir.dot(line_dir)
      c = line_dir.dot(line_dir)
      d = ray_dir.dot(w)
      e = line_dir.dot(w)

      denom = a * c - b * b
      if denom.abs < 0.0001
        # Parallel lines
        t = e / c
      else
        t = (b * d - a * e) / denom
      end

      Geom::Point3d.new(
        line_pt.x + line_dir.x * t,
        line_pt.y + line_dir.y * t,
        line_pt.z + line_dir.z * t
      )
    end
  end

  # ═══════════════════════════════════════════════════════════════
  # MODULE METHODS
  # ═══════════════════════════════════════════════════════════════

  def self.activate_box_tool
    Sketchup.active_model.select_tool(MeasureBoxTool.new)
  end

  def self.activate_box_tool_for_category(cat)
    Sketchup.active_model.select_tool(MeasureBoxTool.new(cat))
  end
end
