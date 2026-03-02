module TakeoffTool
  unless defined?(SF_COLORS)
  SF_COLORS = {
    'Drywall'         => [249, 226, 175, 140],
    'Roofing'         => [150, 170, 210, 140],
    'Metal Roofing'   => [140, 180, 220, 140],
    'Shingle Roofing' => [160, 140, 180, 140],
    'Roof Sheathing'  => [230, 200, 150, 140],
    'Wall Sheathing'  => [210, 200, 160, 140],
    'Flooring'        => [190, 180, 150, 140],
    'Concrete'        => [170, 170, 170, 140],
    'Ceilings'        => [160, 200, 230, 140],
    'Masonry / Veneer'=> [210, 180, 140, 140],
    'Siding'          => [140, 200, 140, 140],
    'Soffit'          => [200, 180, 220, 140],
    'Insulation'      => [255, 180, 220, 140],
    'Membrane'        => [200, 200, 255, 140],
    'Wall Framing'    => [250, 180, 135, 140],
    'Wall Finish'     => [240, 220, 160, 140],
    'Exterior Finish' => [120, 190, 120, 140],
    'Tile'            => [180, 220, 220, 140],
    'Backsplash'      => [200, 180, 200, 140],
    'Shower Walls'    => [160, 210, 210, 140],
    'Custom'          => [200, 200, 100, 140]
  }
  SF_DEFAULT_COLOR = [255, 100, 255, 140]

  SF_CATEGORIES = ['Drywall','Roofing','Metal Roofing','Shingle Roofing',
    'Roof Sheathing','Wall Sheathing','Flooring','Concrete','Ceilings',
    'Masonry / Veneer','Siding','Soffit','Insulation','Membrane',
    'Wall Framing','Wall Finish','Exterior Finish',
    'Tile','Backsplash','Shower Walls','Custom']
  end # unless defined?(SF_COLORS)

  class MeasureSFTool

    def initialize(preset_category = nil)
      @picked_faces = []      # Array of {face:, sf:, original_mat:, transform:}
      @hover_face = nil
      @hover_transform = nil  # World transform for hovered face
      @hover_area = 0
      @total_sf = 0.0
      @preset_category = preset_category
      @dialog_open = false
    end

    def activate
      reset_full
      update_status
    end

    def deactivate(view)
      @pick_dlg.close if @pick_dlg rescue nil
      # Restore original materials on any unsaved picked faces
      @picked_faces.each do |pf|
        begin
          pf[:face].material = pf[:original_mat]
        rescue; end
      end
      reset_full
      view.invalidate
    end

    def resume(view)
      update_status
      view.invalidate
    end

    # ─── Mouse ───

    def onMouseMove(flags, x, y, view)
      return if @dialog_open
      ph = view.pick_helper
      ph.do_pick(x, y)

      face = nil
      xform = nil

      # Drill into nested groups/components to find the actual face
      count = ph.count
      count.times do |i|
        leaf = ph.leaf_at(i)
        if leaf.is_a?(Sketchup::Face)
          face = leaf
          xform = ph.transformation_at(i)
          break
        end
      end

      # Fallback: walk the pick path for the best pick
      if !face
        path = ph.path_at(0)
        if path
          # The leaf (last element) of the path may be the face
          last = path.last
          if last.is_a?(Sketchup::Face)
            face = last
            xform = ph.transformation_at(0)
          end
        end
      end

      if face && !face.equal?(@hover_face)
        @hover_face = face
        @hover_transform = xform || Geom::Transformation.new
        # Calculate area accounting for group/component scaling
        @hover_area = compute_world_area(face, @hover_transform)
        view.invalidate
      elsif !face && @hover_face
        @hover_face = nil
        @hover_transform = nil
        @hover_area = 0
        view.invalidate
      end

      if @hover_face
        sf = @hover_area / 144.0
        view.tooltip = "Face: #{'%.1f' % sf} SF"
      end
    end

    def onLButtonDown(flags, x, y, view)
      return if @dialog_open
      return unless @hover_face

      face = @hover_face

      # Click already-picked face to deselect
      already = @picked_faces.find { |pf| pf[:face].equal?(face) }
      if already
        remove_face(already, view)
        return
      end

      pick_face(face, @hover_transform, view)
    end

    def onLButtonDoubleClick(flags, x, y, view)
      return if @dialog_open
      if @picked_faces.length >= 1
        finish_measurement(view)
      elsif @hover_face
        pick_face(@hover_face, @hover_transform, view)
        finish_measurement(view) if @picked_faces.length >= 1
      end
    end

    def getMenu(menu, flags, x, y, view)
      if @picked_faces.length >= 1
        menu.add_item("Finish (#{'%.1f' % @total_sf} SF)") { finish_measurement(view) }
        menu.add_separator
      end
      if @hover_face
        already = @picked_faces.find { |pf| pf[:face].equal?(@hover_face) }
        if already
          sf = already[:sf]
          menu.add_item("Remove This Face (#{'%.1f' % sf} SF)") { remove_face(already, view) }
        else
          sf = @hover_area / 144.0
          menu.add_item("Add This Face (#{'%.1f' % sf} SF)") { pick_face(@hover_face, @hover_transform, view) }
        end
      end
      menu.add_separator if @picked_faces.length >= 1 || @hover_face
      menu.add_item("Cancel") { cancel(view) }
      true
    end

    # ─── Keyboard ───

    def onKeyDown(key, repeat, flags, view)
      case key
      when 13 # Enter
        finish_measurement(view) if @picked_faces.length >= 1
      end
      # Escape (27) not handled — SketchUp natively pops the tool, triggering deactivate
    end

    # ─── Draw overlay ───

    def draw(view)
      # Yellow highlight on hovered face (if not already picked, and dialog not open)
      if @hover_face && !@dialog_open && !@picked_faces.find { |pf| pf[:face].equal?(@hover_face) }
        draw_face_highlight(view, @hover_face, @hover_transform, Sketchup::Color.new(255, 255, 100, 60))
      end

      if @picked_faces.length > 0
        view.draw_text([10, 10, 0], "#{@picked_faces.length} face#{'s' if @picked_faces.length>1} selected — #{'%.1f' % @total_sf} SF",
          color: Sketchup::Color.new(100, 255, 100))
      end
    end

    def draw_face_highlight(view, face, xform, color)
      begin
        mesh = face.mesh(0)
        pts = []
        (1..mesh.count_points).each do |i|
          pt = mesh.point_at(i)
          # Transform local face points to world space for nested groups
          pts << (xform ? xform * pt : pt)
        end
        return if pts.length < 3
        view.drawing_color = color
        view.draw(GL_POLYGON, pts)
      rescue => e
        # Silently handle invalid face geometry
      end
    end

    def getExtents
      bb = Geom::BoundingBox.new
      @picked_faces.each do |pf|
        begin
          xform = pf[:transform]
          pf[:face].vertices.each do |v|
            pt = xform ? xform * v.position : v.position
            bb.add(pt)
          end
        rescue; end
      end
      bb
    end

    private

    # Compute face area in world coordinates, accounting for group scaling.
    # face.area returns area in the face's local coordinate system.
    # If the containing group is scaled, we need to adjust.
    def compute_world_area(face, xform)
      return face.area unless xform

      begin
        # Extract scale factors from transformation axes
        sx = Geom::Vector3d.new(xform.xaxis).length
        sy = Geom::Vector3d.new(xform.yaxis).length
        sz = Geom::Vector3d.new(xform.zaxis).length

        # If uniform scaling (or identity), simple multiply
        if (sx - sy).abs < 0.001 && (sy - sz).abs < 0.001
          return face.area * sx * sy
        end

        # Non-uniform: transform each mesh triangle and sum areas
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
        face.area  # Fallback to local area
      end
    end

    def pick_face(face, xform, view)
      orig_mat = face.material
      sf = compute_world_area(face, xform) / 144.0

      # Apply temporary green highlight to indicate selection
      begin
        highlight_mat = get_or_create_highlight_mat
        face.material = highlight_mat
      rescue => e
        puts "Takeoff SF: Could not highlight face (may be inside locked component): #{e.message}"
      end

      @picked_faces << { face: face, sf: sf, original_mat: orig_mat, transform: xform }
      @total_sf += sf

      update_vcb
      update_status
      view.invalidate
      puts "Takeoff SF: Picked face #{'%.1f' % sf} SF (total: #{'%.1f' % @total_sf} SF, #{@picked_faces.length} faces)"
    end

    def remove_face(pf, view)
      begin
        pf[:face].material = pf[:original_mat]
      rescue; end
      @total_sf -= pf[:sf]
      @picked_faces.delete(pf)
      update_vcb
      update_status
      view.invalidate
    end

    def cancel(view)
      Sketchup.active_model.select_tool(nil)
    end

    def reset_full
      @picked_faces = []
      @hover_face = nil
      @hover_transform = nil
      @hover_area = 0
      @total_sf = 0.0
      update_vcb
    end

    def update_vcb
      Sketchup.vcb_label = "Total SF"
      Sketchup.vcb_value = "#{'%.1f' % @total_sf} SF"
    end

    def update_status
      n = @picked_faces.length
      cat_label = @preset_category ? " [#{@preset_category}]" : ""
      if n == 0
        Sketchup.status_text = "SF Tool#{cat_label}: Click faces to select. Click selected face to deselect. Enter/Dbl-click to finish. Esc to cancel."
      else
        Sketchup.status_text = "SF Tool#{cat_label}: #{n} face#{'s' if n>1}, #{'%.1f' % @total_sf} SF — Click more / click to deselect / Enter to finish / Esc to cancel."
      end
    end

    def get_or_create_highlight_mat
      model = Sketchup.active_model
      mat = model.materials['TO_SF_Highlight']
      unless mat
        mat = model.materials.add('TO_SF_Highlight')
        mat.color = Sketchup::Color.new(100, 255, 100)
        mat.alpha = 0.5
      end
      mat
    end

    # ─── Finish ───

    def finish_measurement(view)
      return if @picked_faces.empty?

      if @preset_category
        @last_cat = @preset_category
        @last_cc = ''
        @last_note = ''
        on_sf_ok(@preset_category, '', '', view)
        return
      end

      sf_tool = self
      total_sf = @total_sf
      saved_faces = @picked_faces.dup

      all_cats = TakeoffTool.master_categories
      default_cat = @last_cat || 'Drywall'
      cat_options = all_cats.map { |c|
        sel = c == default_cat ? ' selected' : ''
        "<option value=\"#{c}\"#{sel}>#{c}</option>"
      }.join
      cat_options += '<option value="__custom__">+ Custom...</option>'

      html = <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <style>#{PICK_DIALOG_CSS}
        body{overflow-y:auto}
        #customRow{display:none;margin-top:8px}
        #customRow.show{display:block}
        #customName{width:100%;padding:8px 10px;background:#313244;color:#cdd6f4;border:1px solid #585b70;border-radius:6px;font-size:13px;font-family:inherit}
        #customName:focus{outline:none;border-color:#89b4fa}
        </style></head><body>
        <h1>SF Measurement &mdash; #{'%.1f' % total_sf} SF</h1>
        <label>Category</label>
        <select id="cat" onchange="onCatChange()">#{cat_options}</select>
        <div id="customRow"><label>New category name</label><input id="customName" type="text" placeholder="Enter name..."></div>
        <label>Cost Code (optional)</label>
        <input id="cc" type="text" value="#{(@last_cc || '').gsub('"', '&quot;')}">
        <label>Note (optional)</label>
        <input id="note" type="text" value="">
        <div class="buttons">
          <button class="btn btn-cancel" onclick="sketchup.cancel()">Cancel</button>
          <button class="btn btn-ok" onclick="doOk()">OK</button>
        </div>
        <script>
        function onCatChange(){document.getElementById('customRow').className=document.getElementById('cat').value==='__custom__'?'show':'';}
        function doOk(){
          var cat=document.getElementById('cat').value;
          if(cat==='__custom__'){cat=document.getElementById('customName').value.trim();if(!cat)return;}
          sketchup.ok(JSON.stringify({cat:cat,cc:document.getElementById('cc').value,note:document.getElementById('note').value}));
        }
        document.addEventListener('keydown',function(e){if(e.key==='Escape')sketchup.cancel();});
        </script>
        </body></html>
      HTML

      @pick_dlg.close if @pick_dlg rescue nil
      @pick_dlg = UI::HtmlDialog.new(
        dialog_title: "SF Measurement",
        preferences_key: "TakeoffSFPick",
        width: 320, height: 400,
        left: 200, top: 200,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @pick_dlg.add_action_callback('ok') do |_ctx, json_str|
        @pick_dlg.close rescue nil
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          cc = data['cc'].to_s
          note = data['note'].to_s
          unless cat.empty?
            sf_tool.send(:on_sf_ok, cat, cc, note, view, saved_faces, total_sf)
          end
        rescue => e
          puts "Takeoff SF: OK callback error: #{e.message}"
        end
      end

      @pick_dlg.add_action_callback('cancel') do |_ctx|
        @pick_dlg.close rescue nil
        @dialog_open = false
        Sketchup.status_text = "SF Tool: Category cancelled. Faces still selected. Enter to try again, Esc to cancel."
      end

      @dialog_open = true
      @pick_dlg.set_html(html)
      @pick_dlg.show
    end

    def on_sf_ok(cat, cc, note, view, saved_faces = nil, saved_total_sf = nil)
      @dialog_open = false
      # Persist custom category if new
      TakeoffTool.add_custom_category(cat) unless TakeoffTool.master_categories.include?(cat)
      # Restore captured state if provided (async dialog path)
      @picked_faces = saved_faces if saved_faces
      @total_sf = saved_total_sf if saved_total_sf
      return if @picked_faces.empty?
      @last_cat = cat
      @last_cc = cc
      @last_note = note
      apply_final_color(cat)
      grp = create_sf_record(cat)
      # Stamp group_eid on each face so we can link faces back to measurement group
      @picked_faces.each do |pf|
        begin
          pf[:face].set_attribute('FF_Original', 'group_eid', grp.entityID)
        rescue; end
      end
      add_to_results(cat, grp)
      Sketchup.status_text = "SF Tool: Saved #{'%.1f' % @total_sf} SF of #{cat}. Click to start new measurement."
      reset_full
      view.invalidate
    end

    def apply_final_color(cat)
      model = Sketchup.active_model
      model.start_operation('SF Color', true)

      rgba = SF_COLORS[cat] || SF_DEFAULT_COLOR
      mat_name = "TO_SF_#{cat.gsub(/[\s\/]+/,'_')}"
      mat = model.materials[mat_name]
      unless mat
        mat = model.materials.add(mat_name)
        mat.color = Sketchup::Color.new(rgba[0], rgba[1], rgba[2])
        mat.alpha = (rgba[3] || 140) / 255.0
      end

      @picked_faces.each do |pf|
        begin
          f = pf[:face]
          orig_name = pf[:original_mat] ? pf[:original_mat].display_name : ''
          f.set_attribute('FF_Original', 'material', orig_name)
          f.material = mat
        rescue => e
          puts "Takeoff SF: Failed to color face: #{e.message}"
        end
      end

      model.commit_operation
    end

    def create_sf_record(cat)
      model = Sketchup.active_model
      model.start_operation('SF Record', true)

      tag = model.layers[LF_TAG] || model.layers.add(LF_TAG)

      grp = model.active_entities.add_group
      grp.layer = tag
      grp.name = "TO_SF: #{cat} #{'%.1f' % @total_sf} SF"

      # Place construction point at world-space center of first face
      center = Geom::Point3d.new(0, 0, 0)
      if @picked_faces.length > 0
        begin
          fc = @picked_faces.first
          local_center = fc[:face].bounds.center
          center = fc[:transform] ? fc[:transform] * local_center : local_center
        rescue; end
      end
      grp.entities.add_cpoint(center)
      grp.hidden = true

      grp.set_attribute('TakeoffMeasurement', 'type', 'SF')
      grp.set_attribute('TakeoffMeasurement', 'category', cat)
      grp.set_attribute('TakeoffMeasurement', 'total_sf', @total_sf)
      grp.set_attribute('TakeoffMeasurement', 'face_count', @picked_faces.length)
      grp.set_attribute('TakeoffMeasurement', 'cost_code', @last_cc || '')
      grp.set_attribute('TakeoffMeasurement', 'note', @last_note || '')
      grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
      grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)

      # Store face references for show/hide toggling
      require 'json'
      refs = @picked_faces.map do |pf|
        f = pf[:face]
        pid = f.respond_to?(:persistent_id) ? f.persistent_id : nil
        parent = f.parent
        defn_name = if parent.is_a?(Sketchup::ComponentDefinition)
                      parent.name
                    else
                      '__model__'
                    end
        fidx = begin
          parent_ents = parent.is_a?(Sketchup::ComponentDefinition) ? parent.entities : model.entities
          parent_ents.grep(Sketchup::Face).index(f) || -1
        rescue
          -1
        end
        { 'pid' => pid, 'defn' => defn_name, 'fidx' => fidx }
      end
      grp.set_attribute('TakeoffMeasurement', 'face_refs', JSON.generate(refs))

      # Store material info for re-coloring
      rgba = SF_COLORS[cat] || SF_DEFAULT_COLOR
      mat_name = "TO_SF_#{cat.gsub(/[\s\/]+/,'_')}"
      grp.set_attribute('TakeoffMeasurement', 'material_name', mat_name)
      grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate(rgba))

      TakeoffTool.entity_registry[grp.entityID] = grp

      model.commit_operation
      grp
    end

    def add_to_results(cat, grp)
      face_count = @picked_faces.length
      eid = grp.entityID

      result = {
        entity_id: eid,
        tag: LF_TAG,
        definition_name: "Manual SF: #{cat}",
        display_name: "📐 #{cat} — #{'%.1f' % @total_sf} SF (#{face_count} face#{'s' if face_count>1})#{@last_note && !@last_note.empty? ? ' — ' + @last_note : ''}",
        material: '',
        is_solid: false,
        instance_count: 1,
        volume_ft3: 0.0,
        volume_bf: 0.0,
        area_sf: @total_sf,
        linear_ft: 0.0,
        bb_width_in: 0, bb_height_in: 0, bb_depth_in: 0,
        ifc_type: nil,
        warnings: [],
        parsed: {
          auto_category: cat,
          element_type: 'Manual Measurement',
          function: 'SF',
          material: @last_note || '',
          thickness: '',
          size_nominal: '',
          revit_id: nil
        },
        source: :manual_sf
      }

      TakeoffTool.scan_results << result
      TakeoffTool.category_assignments[eid] = cat
      if @last_cc && !@last_cc.empty?
        TakeoffTool.cost_code_assignments[eid] = @last_cc
      end

      # Refresh dashboard
      d = Dashboard.instance_variable_get(:@dialog)
      if d && d.visible?
        Dashboard.send_data(TakeoffTool.scan_results, TakeoffTool.category_assignments, TakeoffTool.cost_code_assignments)
      end

      puts "Takeoff SF: Added #{cat} #{'%.1f' % @total_sf} SF #{face_count} faces (entity #{eid})"
    end
  end

  def self.activate_sf_tool
    Sketchup.active_model.select_tool(MeasureSFTool.new)
  end

  def self.activate_sf_tool_for_category(cat)
    Sketchup.active_model.select_tool(MeasureSFTool.new(cat))
  end
end
