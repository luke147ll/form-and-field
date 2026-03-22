module TakeoffTool
  unless defined?(SF_COLORS)
  SF_COLORS = {}
  SF_DEFAULT_COLOR = [166, 227, 161, 255]

  # Catppuccin Mocha palette for SF measurement color picker
  SF_COLOR_PALETTE = [
    { name: 'Green',     rgb: [166, 227, 161] },
    { name: 'Blue',      rgb: [137, 180, 250] },
    { name: 'Peach',     rgb: [250, 179, 135] },
    { name: 'Mauve',     rgb: [203, 166, 247] },
    { name: 'Yellow',    rgb: [249, 226, 175] },
    { name: 'Teal',      rgb: [148, 226, 213] },
    { name: 'Sky',       rgb: [137, 220, 235] },
    { name: 'Pink',      rgb: [245, 194, 231] },
    { name: 'Flamingo',  rgb: [242, 205, 205] },
    { name: 'Red',       rgb: [243, 139, 168] },
    { name: 'Lavender',  rgb: [180, 190, 254] },
    { name: 'Sapphire',  rgb: [116, 199, 236] },
  ]

  SF_CATEGORIES = ['Drywall','Roofing','Metal Roofing','Shingle Roofing',
    'Roof Sheathing','Wall Sheathing','Flooring','Concrete','Ceilings',
    'Masonry / Veneer','Siding','Soffit','Insulation','Membrane',
    'Wall Framing','Wall Finish','Exterior Finish',
    'Tile','Backsplash','Shower Walls','Custom']
  end # unless defined?(SF_COLORS)

  def self.refresh_sf_material_colors
    m = Sketchup.active_model
    return unless m
    green = Sketchup::Color.new(166, 227, 161)
    # Reset legacy TO_SF_ and debug materials
    m.materials.each do |mat|
      if mat.name.start_with?('TO_SF_')
        mat.color = green
        mat.alpha = 1.0
      end
    end
    measured = m.materials['FF_DEBUG_MEASURED']
    if measured
      measured.color = green
      measured.alpha = 1.0
    end
    excluded = m.materials['FF_DEBUG_EXCLUDED']
    if excluded
      excluded.color = Sketchup::Color.new(243, 139, 168)
      excluded.alpha = 1.0
    end
    # Restore per-group face materials from saved color_rgba attribute
    require 'json'
    m.start_operation('Restore measurement colors', true)
    m.entities.grep(Sketchup::Group).each do |grp|
      next unless grp.valid?
      mtype = grp.get_attribute('TakeoffMeasurement', 'type')
      next unless mtype == 'SF' || mtype == 'LF' || mtype == 'VOL'
      rgba_json = grp.get_attribute('TakeoffMeasurement', 'color_rgba')
      next unless rgba_json
      rgba = (JSON.parse(rgba_json) rescue nil)
      next unless rgba.is_a?(Array) && rgba.length >= 3
      r, g, b = rgba[0].to_i, rgba[1].to_i, rgba[2].to_i
      prefix = mtype == 'SF' ? 'FF_SF_' : mtype == 'VOL' ? 'FF_VOL_' : 'FF_LF_'
      alpha = mtype == 'SF' ? 0.6 : mtype == 'VOL' ? 0.4 : 0.7
      mat_name = "#{prefix}#{grp.entityID}"
      mat = m.materials[mat_name] || m.materials.add(mat_name)
      mat.color = Sketchup::Color.new(r, g, b)
      mat.alpha = alpha
      if mtype == 'VOL'
        # VOL markers are sub-groups with faces inside
        grp.entities.grep(Sketchup::Group).each do |marker|
          next unless marker.valid?
          marker.entities.grep(Sketchup::Face).each do |face|
            face.material = mat
            face.back_material = mat
          end
        end
      else
        grp.entities.grep(Sketchup::Face).each do |face|
          face.material = mat
          face.back_material = mat
        end
      end
    end
    m.commit_operation
  end

  # ═══════════════════════════════════════════════════════════
  #  MeasureSFTool — click model faces to create physical
  #  measurement geometry. Flood-fills coplanar neighbors,
  #  projects a flat face, offsets toward camera.
  # ═══════════════════════════════════════════════════════════

  class MeasureSFTool
    FLOOD_ANGLE_TOL = 5.0   # degrees — coplanar threshold
    OFFSET_DIST     = 0.5   # inches — offset toward camera

    def initialize(category, opts = {})
      @category = category
      @group_eid = opts[:group_eid]    # target specific group, or nil for new
      @label = opts[:label] || category # sub-label (e.g., "Tile", "Wood")
      @color_rgb = opts[:color]         # [r,g,b] or nil for default green
      @part_link_id = opts[:part_link_id] # derived part ID to link on deactivate
      @hover_face = nil
      @hover_xform = nil
      @hover_cluster = nil
      @hover_boundary = nil
      @hover_sf = 0.0
      @remove_hover_face = nil   # Ctrl+click removal target
      @measurement_group = nil
      @total_sf = 0.0
      @face_count = 0
    end

    def activate
      find_or_create_group
      recompute_totals
      display = @label != @category ? "#{@category} / #{@label}" : @category
      Sketchup.status_text = "Measure SF [#{display}]: Click faces to add. Ctrl+Click to remove. Total = #{'%.1f' % @total_sf} SF. Escape to finish."
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
          puts "Takeoff: SF part link error: #{e.message}"
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
      Sketchup.status_text = "Measure SF [#{display}]: #{'%.1f' % @total_sf} SF (#{@face_count} faces). Click to add, Ctrl+Click to remove. Escape to finish."
      view.invalidate
    end

    # ─── Mouse ───

    def onMouseMove(flags, x, y, view)
      ctrl = (flags & COPY_MODIFIER_MASK) != 0
      ph = view.pick_helper
      ph.do_pick(x, y)

      if ctrl && @measurement_group && @measurement_group.valid?
        # ── Ctrl held: pick faces inside the measurement group for removal ──
        @hover_face = nil; @hover_cluster = nil; @hover_boundary = nil; @hover_sf = 0.0
        found = nil
        ph.count.times do |i|
          leaf = ph.leaf_at(i)
          if leaf.is_a?(Sketchup::Face)
            path = ph.path_at(i)
            if path && path.include?(@measurement_group)
              found = leaf
              break
            end
          end
        end
        if found != @remove_hover_face
          @remove_hover_face = found
          if found
            sf = found.area / 144.0
            view.tooltip = "Ctrl+Click to remove: #{'%.1f' % sf} SF"
          end
          view.invalidate
        end
        return
      end

      # ── Normal mode: pick model faces for addition ──
      @remove_hover_face = nil

      face = nil
      xform = nil

      ph.count.times do |i|
        leaf = ph.leaf_at(i)
        if leaf.is_a?(Sketchup::Face)
          # Skip faces inside our own measurement group
          path = ph.path_at(i)
          next if path && path.any? { |e| e == @measurement_group }
          face = leaf
          xform = ph.transformation_at(i)
          break
        end
      end

      if !face
        path = ph.path_at(0)
        if path && path.last.is_a?(Sketchup::Face)
          unless path.any? { |e| e == @measurement_group }
            face = path.last
            xform = ph.transformation_at(0)
          end
        end
      end

      if face && !face.equal?(@hover_face)
        @hover_face = face
        @hover_xform = xform || Geom::Transformation.new
        @hover_cluster = flood_fill_coplanar(face, @hover_xform)
        @hover_boundary = extract_outer_boundary(@hover_cluster, @hover_xform)
        @hover_sf = @hover_cluster.sum { |f| compute_world_area(f, @hover_xform) } / 144.0
        view.tooltip = "Cluster: #{'%.1f' % @hover_sf} SF (#{@hover_cluster.length} faces)"
        view.invalidate
      elsif !face && @hover_face
        @hover_face = nil
        @hover_xform = nil
        @hover_cluster = nil
        @hover_boundary = nil
        @hover_sf = 0.0
        view.invalidate
      end
    end

    def onLButtonDown(flags, x, y, view)
      ctrl = (flags & COPY_MODIFIER_MASK) != 0

      # ── Ctrl+Click: remove a face from the measurement group ──
      if ctrl && @remove_hover_face && @remove_hover_face.valid? &&
         @measurement_group && @measurement_group.valid?
        model = Sketchup.active_model
        model.start_operation('Remove SF Face', false)
        begin
          edges = @remove_hover_face.edges.dup
          @remove_hover_face.erase!
          @remove_hover_face = nil
          edges.each { |e| e.erase! if e.valid? && e.faces.empty? }
          recompute_totals
          update_group_attributes
          model.commit_operation
          display = @label != @category ? "#{@category} / #{@label}" : @category
          Sketchup.status_text = "Measure SF [#{display}]: #{'%.1f' % @total_sf} SF (#{@face_count} faces). Ctrl+Click to remove more. Escape to finish."
        rescue => e
          model.abort_operation
          puts "MeasureSF remove error: #{e.message}"
        end
        view.invalidate
        return
      end

      # ── Normal click: add a face ──
      return unless @hover_face && @hover_cluster && @hover_boundary
      return if @hover_boundary.length < 3

      model = Sketchup.active_model
      model.start_operation('Add SF Face', false)

      begin
        # Compute best-fit plane
        centroid, normal = compute_best_fit_plane(@hover_cluster, @hover_xform)
        return model.abort_operation unless centroid && normal

        # Project boundary onto plane and offset toward camera
        offset_pts = project_and_offset(@hover_boundary, centroid, normal, view)
        return model.abort_operation if offset_pts.length < 3

        # Create face in measurement group
        find_or_create_group unless @measurement_group && @measurement_group.valid?
        new_face = @measurement_group.entities.add_face(offset_pts)
        if new_face
          mat = get_sf_material(model)
          new_face.material = mat
          new_face.back_material = mat
        end

        recompute_totals
        update_group_attributes
        model.commit_operation

        display = @label != @category ? "#{@category} / #{@label}" : @category
        Sketchup.status_text = "Measure SF [#{display}]: #{'%.1f' % @total_sf} SF (#{@face_count} faces). Click to add more. Escape to finish."
      rescue => e
        model.abort_operation
        puts "MeasureSF error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
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
      # ── Ctrl remove mode: red highlight on the targeted face ──
      if @remove_hover_face && @remove_hover_face.valid?
        begin
          xform = @measurement_group ? @measurement_group.transformation : Geom::Transformation.new
          mesh = @remove_hover_face.mesh(0)
          pts = []
          (1..mesh.count_points).each do |i|
            pts << (xform * mesh.point_at(i))
          end
          if pts.length >= 3
            view.drawing_color = Sketchup::Color.new(243, 139, 168, 120)
            view.draw(GL_POLYGON, pts)
          end
        rescue
        end
        return
      end

      # ── Normal mode: green flood-fill highlight ──
      return unless @hover_cluster && @hover_cluster.any?
      begin
        r, g, b = active_color_rgb
        view.drawing_color = Sketchup::Color.new(r, g, b, 80)
        @hover_cluster.each do |face|
          mesh = face.mesh(0)
          pts = []
          (1..mesh.count_points).each do |i|
            pt = mesh.point_at(i)
            pts << (@hover_xform ? @hover_xform * pt : pt)
          end
          next if pts.length < 3
          view.draw(GL_POLYGON, pts)
        end

        if @hover_boundary && @hover_boundary.length >= 3
          view.line_width = 2
          view.drawing_color = Sketchup::Color.new(r, g, b, 200)
          loop_pts = @hover_boundary + [@hover_boundary.first]
          view.draw(GL_LINE_STRIP, loop_pts)
        end
      rescue
      end
    end

    def getExtents
      bb = Geom::BoundingBox.new
      if @hover_boundary
        @hover_boundary.each { |pt| bb.add(pt) }
      end
      bb
    end

    private

    # ─── Flood Fill ───

    def flood_fill_coplanar(seed_face, xform)
      seed_normal = TakeoffTool.get_world_normal(seed_face, xform)
      cos_threshold = Math.cos(FLOOD_ANGLE_TOL * Math::PI / 180.0)
      seed_parent = seed_face.parent

      visited = { seed_face.entityID => true }
      cluster = [seed_face]
      queue = [seed_face]

      while (current = queue.shift)
        current.edges.each do |edge|
          edge.faces.each do |neighbor|
            next if visited[neighbor.entityID]
            next if neighbor.parent != seed_parent
            visited[neighbor.entityID] = true

            n_normal = TakeoffTool.get_world_normal(neighbor, xform)
            if seed_normal.dot(n_normal) >= cos_threshold
              cluster << neighbor
              queue << neighbor
            end
          end
        end
      end

      cluster
    end

    # ─── Boundary Extraction ───

    def extract_outer_boundary(cluster, xform)
      return [] if cluster.empty?

      # Single face — just return its outer loop vertices
      if cluster.length == 1
        return cluster[0].outer_loop.vertices.map { |v| xform * v.position }
      end

      # Build set of cluster face IDs
      cluster_ids = {}
      cluster.each { |f| cluster_ids[f.entityID] = true }

      # Find boundary edges (belong to exactly 1 cluster face)
      boundary_edges = []
      edge_seen = {}
      cluster.each do |face|
        face.edges.each do |edge|
          next if edge_seen[edge.entityID]
          edge_seen[edge.entityID] = true
          cluster_count = edge.faces.count { |f| cluster_ids[f.entityID] }
          boundary_edges << edge if cluster_count == 1
        end
      end

      return [] if boundary_edges.empty?
      order_boundary_edges(boundary_edges, xform)
    end

    def order_boundary_edges(edges, xform)
      # Build vertex → edges adjacency
      vert_edges = {}
      edges.each do |e|
        e.vertices.each do |v|
          vert_edges[v.entityID] ||= []
          vert_edges[v.entityID] << e
        end
      end

      loop_pts = []
      used = {}
      current_edge = edges.first
      current_vert = current_edge.start

      loop do
        loop_pts << (xform * current_vert.position)
        used[current_edge.entityID] = true
        other_vert = current_edge.other_vertex(current_vert)

        candidates = (vert_edges[other_vert.entityID] || []).reject { |e| used[e.entityID] }
        break if candidates.empty?
        current_edge = candidates.first
        current_vert = other_vert
      end

      loop_pts
    end

    # ─── Plane Projection ───

    def compute_best_fit_plane(cluster, xform)
      total_area = 0.0
      wx = 0.0; wy = 0.0; wz = 0.0
      cx = 0.0; cy = 0.0; cz = 0.0

      cluster.each do |face|
        area = compute_world_area(face, xform)
        normal = TakeoffTool.get_world_normal(face, xform)
        center = xform * face.bounds.center

        wx += normal.x * area
        wy += normal.y * area
        wz += normal.z * area

        cx += center.x * area
        cy += center.y * area
        cz += center.z * area

        total_area += area
      end

      return nil if total_area < 0.001

      avg_normal = Geom::Vector3d.new(wx, wy, wz)
      avg_normal.normalize!
      centroid = Geom::Point3d.new(cx / total_area, cy / total_area, cz / total_area)

      [centroid, avg_normal]
    end

    def project_and_offset(boundary_pts, plane_pt, plane_normal, view)
      # Determine offset direction (toward camera)
      cam_eye = view.camera.eye
      to_cam = cam_eye - plane_pt
      dot = to_cam.x * plane_normal.x + to_cam.y * plane_normal.y + to_cam.z * plane_normal.z
      offset_dir = dot >= 0 ? plane_normal : plane_normal.reverse
      offset_vec = Geom::Vector3d.new(
        offset_dir.x * OFFSET_DIST,
        offset_dir.y * OFFSET_DIST,
        offset_dir.z * OFFSET_DIST
      )

      boundary_pts.map do |pt|
        # Project onto plane: pt' = pt - ((pt - plane_pt) · normal) * normal
        diff = pt - plane_pt
        dist_to_plane = diff.x * plane_normal.x + diff.y * plane_normal.y + diff.z * plane_normal.z
        projected = Geom::Point3d.new(
          pt.x - dist_to_plane * plane_normal.x,
          pt.y - dist_to_plane * plane_normal.y,
          pt.z - dist_to_plane * plane_normal.z
        )
        # Offset toward camera
        Geom::Point3d.new(
          projected.x + offset_vec.x,
          projected.y + offset_vec.y,
          projected.z + offset_vec.z
        )
      end
    end

    # ─── Geometry Helpers ───

    def compute_world_area(face, xform)
      return face.area unless xform
      begin
        sx = Geom::Vector3d.new(xform.xaxis).length
        sy = Geom::Vector3d.new(xform.yaxis).length
        sz = Geom::Vector3d.new(xform.zaxis).length
        if (sx - sy).abs < 0.001 && (sy - sz).abs < 0.001
          return face.area * sx * sy
        end
        mesh = face.mesh(0)
        total = 0.0
        (1..mesh.count_polygons).each do |pi|
          tri = mesh.polygon_points_at(pi)
          next unless tri && tri.length >= 3
          p0 = xform * tri[0]
          p1 = xform * tri[1]
          p2 = xform * tri[2]
          v1 = p1 - p0
          v2 = p2 - p0
          total += v1.cross(v2).length / 2.0
        end
        total
      rescue
        face.area
      end
    end

    def active_color_rgb
      @color_rgb || begin
        if @measurement_group && @measurement_group.valid?
          require 'json'
          rgba_json = @measurement_group.get_attribute('TakeoffMeasurement', 'color_rgba')
          arr = rgba_json ? (JSON.parse(rgba_json) rescue nil) : nil
          arr && arr.length >= 3 ? arr[0..2] : [166, 227, 161]
        else
          [166, 227, 161]
        end
      end
    end

    def get_sf_material(model)
      r, g, b = active_color_rgb
      # Per-group material keyed by group eid to avoid color conflicts
      eid = @measurement_group ? @measurement_group.entityID : 0
      mat_name = "FF_SF_#{eid}"
      mat = model.materials[mat_name] || model.materials.add(mat_name)
      mat.color = Sketchup::Color.new(r, g, b)
      mat.alpha = 0.6
      mat
    end

    def find_or_create_group
      m = Sketchup.active_model
      return unless m

      # Target specific group by eid if provided
      if @group_eid
        grp = TakeoffTool.find_entity(@group_eid)
        if grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'SF'
          @measurement_group = grp
          @label = grp.get_attribute('TakeoffMeasurement', 'label') || @label
          return
        end
      end

      # Create new group with label and color
      require 'json'
      tag_name = 'TO_Measurements'
      tag = m.layers[tag_name] || m.layers.add(tag_name)
      r, g, b = @color_rgb || [166, 227, 161]

      @measurement_group = m.active_entities.add_group
      @measurement_group.layer = tag
      @measurement_group.name = "TO_SF: #{@label} — 0.0 SF"
      @measurement_group.set_attribute('TakeoffMeasurement', 'type', 'SF')
      @measurement_group.set_attribute('TakeoffMeasurement', 'category', @category)
      @measurement_group.set_attribute('TakeoffMeasurement', 'label', @label)
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_sf', 0.0)
      @measurement_group.set_attribute('TakeoffMeasurement', 'face_count', 0)
      @measurement_group.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
      @measurement_group.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      @measurement_group.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([r, g, b, 153]))
      @measurement_group.set_attribute('TakeoffMeasurement', 'material_name', "FF_SF_#{@measurement_group.entityID}")

      # Mark as child measurement if linked to a derived part
      if @part_link_id
        @measurement_group.set_attribute('TakeoffMeasurement', 'part_link', @part_link_id)
      end

      # Register in entity cache so find_entity can locate this group
      TakeoffTool.entity_registry[@measurement_group.entityID] = @measurement_group
      TakeoffTool.invalidate_entity_cache
    end

    def recompute_totals
      if @measurement_group && @measurement_group.valid?
        faces = @measurement_group.entities.grep(Sketchup::Face)
        @face_count = faces.length
        @total_sf = (faces.sum { |f| f.area } / 144.0).round(2)
      else
        @face_count = 0
        @total_sf = 0.0
      end
    end

    def update_group_attributes
      return unless @measurement_group && @measurement_group.valid?
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_sf', @total_sf)
      @measurement_group.set_attribute('TakeoffMeasurement', 'face_count', @face_count)
      @measurement_group.name = "TO_SF: #{@label} — #{'%.1f' % @total_sf} SF"
      @measurement_group.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
    end
  end

  # ═══════════════════════════════════════════════════════════
  #  RemoveSFFaceTool — click faces inside a measurement group
  #  to delete them. Totals update automatically.
  # ═══════════════════════════════════════════════════════════

  class RemoveSFFaceTool
    def initialize(group_eid)
      @group_eid = group_eid.to_i
      @measurement_group = nil
      @hover_face = nil
      @label = nil
    end

    def activate
      m = Sketchup.active_model
      return Sketchup.active_model.select_tool(nil) unless m

      grp = TakeoffTool.find_entity(@group_eid)
      mtype = grp ? grp.get_attribute('TakeoffMeasurement', 'type') : nil
      if grp && grp.valid? && (mtype == 'SF' || mtype == 'LF')
        @measurement_group = grp
        @mtype = mtype
        @label = grp.get_attribute('TakeoffMeasurement', 'label') || grp.get_attribute('TakeoffMeasurement', 'category') || mtype
      end

      unless @measurement_group
        puts "RemoveFace: No SF/LF measurement group found for eid=#{@group_eid}"
        Sketchup.active_model.select_tool(nil)
        return
      end

      @measurement_group.visible = true
      face_count = @measurement_group.entities.grep(Sketchup::Face).length
      Sketchup.status_text = "Remove #{@mtype} [#{@label}]: Click measurement faces to remove (#{face_count} faces). Escape to finish."
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
        face_count = @measurement_group.entities.grep(Sketchup::Face).length
        Sketchup.status_text = "Remove #{@mtype} [#{@label}]: Click measurement faces to remove (#{face_count} faces). Escape to finish."
      end
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      @hover_face = nil
      return unless @measurement_group && @measurement_group.valid?

      ph = view.pick_helper
      ph.do_pick(x, y)

      ph.count.times do |i|
        leaf = ph.leaf_at(i)
        if leaf.is_a?(Sketchup::Face)
          # Only pick faces inside our measurement group
          path = ph.path_at(i)
          if path && path.include?(@measurement_group)
            @hover_face = leaf
            if @mtype == 'LF'
              lf = leaf.area / RIBBON_WIDTH / 12.0
              view.tooltip = "Click to remove: #{'%.1f' % lf} LF"
            else
              sf = leaf.area / 144.0
              view.tooltip = "Click to remove: #{'%.1f' % sf} SF"
            end
            break
          end
        end
      end

      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return unless @hover_face && @hover_face.valid?
      return unless @measurement_group && @measurement_group.valid?

      model = Sketchup.active_model
      model.start_operation("Remove #{@mtype} Face", false)
      begin
        edges = @hover_face.edges.dup
        @hover_face.erase!
        @hover_face = nil
        # Clean up orphaned edges (no longer bounding any face)
        edges.each { |e| e.erase! if e.valid? && e.faces.empty? }

        # Update totals based on type
        faces = @measurement_group.entities.grep(Sketchup::Face)
        if @mtype == 'LF'
          total_lf = (faces.sum { |f| f.area / RIBBON_WIDTH } / 12.0).round(2)
          @measurement_group.set_attribute('TakeoffMeasurement', 'total_ft', total_lf)
          @measurement_group.set_attribute('TakeoffMeasurement', 'total_inches', (total_lf * 12).round(2))
          @measurement_group.set_attribute('TakeoffMeasurement', 'segment_count', faces.length)
          @measurement_group.name = "TO_LF: #{@label} — #{'%.1f' % total_lf} LF"
          model.commit_operation
          Sketchup.status_text = "Remove LF [#{@label}]: #{'%.1f' % total_lf} LF (#{faces.length} faces). Click to remove more. Escape to finish."
        else
          total_sf = (faces.sum { |f| f.area } / 144.0).round(2)
          @measurement_group.set_attribute('TakeoffMeasurement', 'total_sf', total_sf)
          @measurement_group.set_attribute('TakeoffMeasurement', 'face_count', faces.length)
          @measurement_group.name = "TO_SF: #{@label} — #{'%.1f' % total_sf} SF"
          model.commit_operation
          Sketchup.status_text = "Remove SF [#{@label}]: #{'%.1f' % total_sf} SF (#{faces.length} faces). Click to remove more. Escape to finish."
        end
      rescue => e
        model.abort_operation
        puts "RemoveFace error: #{e.message}"
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
      return unless @hover_face && @hover_face.valid?
      begin
        mesh = @hover_face.mesh(0)
        pts = []
        xform = @measurement_group ? @measurement_group.transformation : Geom::Transformation.new
        (1..mesh.count_points).each do |i|
          pt = mesh.point_at(i)
          pts << (xform * pt)
        end
        return if pts.length < 3
        view.drawing_color = Sketchup::Color.new(243, 139, 168, 120)
        view.draw(GL_POLYGON, pts)
      rescue
      end
    end

    def getExtents
      Geom::BoundingBox.new
    end
  end

  # ─── Module entry points ───

  def self.activate_sf_tool
    Sketchup.active_model.select_tool(MeasureSFTool.new('Drywall'))
  end

  def self.activate_sf_tool_for_category(cat)
    Sketchup.active_model.select_tool(MeasureSFTool.new(cat))
  end

  def self.activate_sf_tool_for_group(group_eid, category)
    Sketchup.active_model.select_tool(MeasureSFTool.new(category, group_eid: group_eid.to_i))
  end

  def self.activate_sf_tool_new(category, label, color_rgb)
    Sketchup.active_model.select_tool(MeasureSFTool.new(category, label: label, color: color_rgb))
  end

  def self.activate_remove_sf_tool(group_eid)
    Sketchup.active_model.select_tool(RemoveSFFaceTool.new(group_eid))
  end

  def self.update_sf_label(group_eid, new_label)
    grp = find_entity(group_eid.to_i)
    return unless grp && grp.valid?
    m = Sketchup.active_model
    m.start_operation('Rename SF Measurement', true)
    grp.set_attribute('TakeoffMeasurement', 'label', new_label)
    total = grp.get_attribute('TakeoffMeasurement', 'total_sf') || 0
    grp.name = "TO_SF: #{new_label} — #{'%.1f' % total} SF"
    m.commit_operation
  end

  def self.update_sf_color(group_eid, color_rgb)
    grp = find_entity(group_eid.to_i)
    return unless grp && grp.valid?
    m = Sketchup.active_model
    require 'json'
    m.start_operation('Change SF Color', true)
    grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([color_rgb[0], color_rgb[1], color_rgb[2], 153]))
    # Repaint all faces in the group
    r, g, b = color_rgb
    mat_name = "FF_SF_#{grp.entityID}"
    mat = m.materials[mat_name] || m.materials.add(mat_name)
    mat.color = Sketchup::Color.new(r, g, b)
    mat.alpha = 0.6
    grp.entities.grep(Sketchup::Face).each do |face|
      face.material = mat
      face.back_material = mat
    end
    m.commit_operation
  end

  # ═══════════════════════════════════════════════════════════
  #  Normal Sample Tool — single-click face picker to set the
  #  SF normal direction filter for a category
  # ═══════════════════════════════════════════════════════════

  class NormalSampleTool
    def initialize(category)
      @category = category
      @hover_face = nil
      @hover_transform = nil
    end

    def activate
      @hover_face = nil
      @hover_transform = nil
      Sketchup.status_text = "Sample Normal [#{@category}]: Click a face to set the SF normal direction. Esc to cancel."
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      Sketchup.status_text = "Sample Normal [#{@category}]: Click a face to set the SF normal direction. Esc to cancel."
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
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
        wn = TakeoffTool.get_world_normal(face, @hover_transform)
        view.tooltip = "Normal: #{normal_label(wn)}"
        view.invalidate
      elsif !face && @hover_face
        @hover_face = nil; @hover_transform = nil
        view.invalidate
      end
    end

    def onLButtonDown(flags, x, y, view)
      return unless @hover_face
      normal = TakeoffTool.get_world_normal(@hover_face, @hover_transform)
      normal.normalize! if normal.length > 0.001

      require 'json'
      m = Sketchup.active_model
      m.set_attribute('TakeoffSFNormals', @category,
        JSON.generate([normal.x.round(6), normal.y.round(6), normal.z.round(6)]))
      puts "[FF NormalSample] Saved normal for '#{@category}': #{normal_label(normal)} [#{normal.x.round(3)}, #{normal.y.round(3)}, #{normal.z.round(3)}]"

      Scanner.recalculate_sf
      Dashboard.send_live_data if defined?(Dashboard) && Dashboard.respond_to?(:send_live_data)
      Sketchup.active_model.select_tool(nil)
    end

    def onKeyDown(key, repeat, flags, view)
      if key == 27
        Sketchup.active_model.select_tool(nil)
      end
    end

    def onCancel(reason, view)
      Sketchup.active_model.select_tool(nil)
    end

    def draw(view)
      return unless @hover_face
      begin
        mesh = @hover_face.mesh(0)
        pts = []
        (1..mesh.count_points).each do |i|
          pt = mesh.point_at(i)
          pts << (@hover_transform ? @hover_transform * pt : pt)
        end
        return if pts.length < 3
        view.drawing_color = Sketchup::Color.new(203, 166, 247, 60)
        view.draw(GL_POLYGON, pts)
      rescue
      end
    end

    def getExtents
      Geom::BoundingBox.new
    end

    private

    def normal_label(n)
      ax = n.x.abs; ay = n.y.abs; az = n.z.abs
      if az > 0.9
        n.z > 0 ? 'Up' : 'Down'
      elsif ax > 0.9
        n.x > 0 ? 'East' : 'West'
      elsif ay > 0.9
        n.y > 0 ? 'North' : 'South'
      else
        "Custom"
      end
    end
  end

  def self.activate_normal_sample_tool(cat)
    Sketchup.active_model.select_tool(NormalSampleTool.new(cat))
  end
end
