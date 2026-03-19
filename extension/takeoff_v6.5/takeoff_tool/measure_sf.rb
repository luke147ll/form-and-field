module TakeoffTool
  unless defined?(SF_COLORS)
  SF_COLORS = {}
  SF_DEFAULT_COLOR = [166, 227, 161, 255]

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
    m.materials.each do |mat|
      if mat.name.start_with?('TO_SF_')
        mat.color = green
        mat.alpha = 1.0
      end
    end
    # Also fix debug materials
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
    # Also update stored color_rgba on measurement groups
    require 'json'
    m.entities.grep(Sketchup::Group).each do |grp|
      next unless grp.valid?
      next unless grp.get_attribute('TakeoffMeasurement', 'type') == 'SF'
      grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([166, 227, 161, 255]))
    end
  end

  class MeasureSFTool

    def initialize(preset_category = nil)
      @picked_faces = []
      @hover_face = nil
      @hover_transform = nil
      @hover_area = 0
      @total_sf = 0.0
      @preset_category = preset_category
      @panel = nil
      @save_pending = false
    end

    def activate
      reset_full
      open_panel
      update_status
    end

    def deactivate(view)
      close_panel
      @picked_faces.each do |pf|
        begin; pf[:face].material = pf[:original_mat]; rescue; end
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
      return if @save_pending
      ph = view.pick_helper
      ph.do_pick(x, y)

      face = nil
      xform = nil

      count = ph.count
      count.times do |i|
        leaf = ph.leaf_at(i)
        if leaf.is_a?(Sketchup::Face)
          face = leaf
          xform = ph.transformation_at(i)
          break
        end
      end

      if !face
        path = ph.path_at(0)
        if path
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
      return if @save_pending
      return unless @hover_face

      face = @hover_face

      already = @picked_faces.find { |pf| pf[:face].equal?(face) }
      if already
        remove_face(already, view)
        return
      end

      # Auto-detect category from the first picked face's parent entity
      if @picked_faces.empty?
        cat = detect_category_at(x, y, view)
        set_panel_category(cat) if cat
      end

      pick_face(face, @hover_transform, view)
    end

    def onLButtonDoubleClick(flags, x, y, view)
      if @picked_faces.length >= 1
        trigger_save
      elsif @hover_face
        pick_face(@hover_face, @hover_transform, view)
        trigger_save if @picked_faces.length >= 1
      end
    end

    def getMenu(menu, flags, x, y, view)
      if @picked_faces.length >= 1
        menu.add_item("Save (#{'%.1f' % @total_sf} SF)") { trigger_save }
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
      when 13
        trigger_save if @picked_faces.length >= 1
      when 27
        cancel(view)
      end
    end

    def onCancel(reason, view)
      cancel(view)
    end

    # ─── Draw overlay ───

    def draw(view)
      if @hover_face && !@picked_faces.find { |pf| pf[:face].equal?(@hover_face) }
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
          pts << (xform ? xform * pt : pt)
        end
        return if pts.length < 3
        view.drawing_color = color
        view.draw(GL_POLYGON, pts)
      rescue => e
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

    # ─── Panel ───

    def open_panel
      all_cats = TakeoffTool.master_categories
      default_cat = @preset_category || @last_cat || 'Drywall'
      cat_opts = all_cats.map { |c|
        sel = c == default_cat ? ' selected' : ''
        "<option value=\"#{c}\"#{sel}>#{c}</option>"
      }.join
      cat_opts += '<option value="__custom__">+ Custom...</option>'

      @panel = UI::HtmlDialog.new(
        dialog_title: "SF Measurement",
        width: 260, height: 440,
        left: 80, top: 200,
        style: UI::HtmlDialog::STYLE_UTILITY,
        resizable: false
      )

      sf_tool = self

      @panel.add_action_callback('save') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          cc  = data['cc'].to_s
          note = data['note'].to_s
          part_name = data['name'].to_s.strip
          sf_tool.send(:save_measurement, cat, cc, note, part_name) unless cat.empty?
        rescue => e
          puts "Takeoff SF: save error: #{e.message}"
        end
      end

      @panel.add_action_callback('cancel') do |_ctx|
        Sketchup.active_model.select_tool(nil)
      end

      @panel.set_on_closed do
        @panel = nil
        UI.start_timer(0) { Sketchup.active_model.select_tool(nil) }
      end

      @panel.set_html(sf_panel_html(cat_opts))
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
      @panel.execute_script("updateTotal(#{@total_sf},#{@picked_faces.length})") rescue nil
    end

    def trigger_save
      return unless @panel && @picked_faces.length >= 1
      @save_pending = true
      @panel.bring_to_front rescue nil
      @panel.execute_script("focusName()") rescue nil
    end

    def sf_panel_html(cat_options)
      <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font:13px/1.4 'Segoe UI',system-ui,sans-serif;background:#1e1e2e;color:#cdd6f4;padding:14px;overflow:hidden}
        .hdr{font-size:11px;font-weight:700;color:#cba6f7;text-transform:uppercase;letter-spacing:1px;text-align:center;margin-bottom:4px}
        .total-val{font-size:28px;font-weight:700;color:#a6e3a1;text-align:center;margin:4px 0 2px}
        .total-detail{font-size:11px;color:#6c7086;text-align:center;margin-bottom:10px}
        .divider{height:1px;background:#313244;margin:0 -14px 10px}
        label{display:block;color:#a6adc8;font-size:11px;margin-bottom:3px;margin-top:8px;font-weight:600;text-transform:uppercase;letter-spacing:0.5px}
        label:first-of-type{margin-top:0}
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
        <div class="hdr">SF Measurement</div>
        <div class="total-val" id="totalVal">0.0 SF</div>
        <div class="total-detail" id="totalDetail">Click faces to measure</div>
        <div class="divider"></div>
        <label>Name</label>
        <input id="name" type="text" placeholder="e.g. R-19 Batt, 5/8 Board...">
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
        function updateTotal(sf,count){
          document.getElementById('totalVal').textContent=sf.toFixed(1)+' SF';
          document.getElementById('totalDetail').textContent=count+' face'+(count!==1?'s':'')+' selected';
          document.getElementById('saveBtn').disabled=count<1;
        }
        function onCatChange(){document.getElementById('customRow').className=document.getElementById('cat').value==='__custom__'?'show':'';}
        function doSave(){
          var cat=document.getElementById('cat').value;
          if(cat==='__custom__'){cat=document.getElementById('customName').value.trim();if(!cat)return;}
          if(document.getElementById('saveBtn').disabled)return;
          sketchup.save(JSON.stringify({name:document.getElementById('name').value,cat:cat,cc:document.getElementById('cc').value,note:document.getElementById('note').value}));
        }
        function doCancel(){sketchup.cancel();}
        function focusName(){document.getElementById('name').focus();}
        function setCategory(cat){var sel=document.getElementById('cat');for(var i=0;i<sel.options.length;i++){if(sel.options[i].value===cat){sel.selectedIndex=i;onCatChange();return;}}}
        document.addEventListener('keydown',function(e){if(e.key==='Escape')doCancel();});
        </script>
        </body></html>
      HTML
    end

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

    # ─── Measurement ───

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

    def pick_face(face, xform, view)
      orig_mat = face.material
      sf = compute_world_area(face, xform) / 144.0

      begin
        highlight_mat = get_or_create_highlight_mat
        face.material = highlight_mat
      rescue => e
        puts "Takeoff SF: Could not highlight face: #{e.message}"
      end

      @picked_faces << { face: face, sf: sf, original_mat: orig_mat, transform: xform }
      @total_sf += sf

      update_vcb
      update_status
      update_panel
      view.invalidate
      puts "Takeoff SF: Picked face #{'%.1f' % sf} SF (total: #{'%.1f' % @total_sf} SF, #{@picked_faces.length} faces)"
    end

    def remove_face(pf, view)
      begin; pf[:face].material = pf[:original_mat]; rescue; end
      @total_sf -= pf[:sf]
      @picked_faces.delete(pf)
      update_vcb
      update_status
      update_panel
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
      @save_pending = false
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
        Sketchup.status_text = "SF Tool#{cat_label}: Click faces to select. Click selected face to deselect. Enter/Dbl-click to save. Esc to cancel."
      else
        Sketchup.status_text = "SF Tool#{cat_label}: #{n} face#{'s' if n>1}, #{'%.1f' % @total_sf} SF — Click more / click to deselect / Enter to save / Esc to cancel."
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

    # ─── Save ───

    def save_measurement(cat, cc, note, part_name = '')
      return if @picked_faces.empty?

      TakeoffTool.add_custom_category(cat) unless TakeoffTool.master_categories.include?(cat)
      @last_cat = cat
      @last_cc = cc
      @last_note = note
      @last_part_name = part_name || ''

      # Set category measurement type to SF if not already set
      m = Sketchup.active_model
      existing_mt = m.get_attribute('TakeoffMeasurementTypes', cat) rescue nil
      m.set_attribute('TakeoffMeasurementTypes', cat, 'sf') if !existing_mt || existing_mt.empty?

      apply_final_color(cat)
      grp = create_sf_record(cat)
      @picked_faces.each do |pf|
        begin; pf[:face].set_attribute('FF_Original', 'group_eid', grp.entityID); rescue; end
      end
      add_to_results(cat, grp)

      Sketchup.status_text = "SF Tool: Saved #{'%.1f' % @total_sf} SF of #{cat}. Click to start new measurement."
      reset_full
      update_panel
      Sketchup.active_model.active_view.invalidate
    end

    def apply_final_color(cat)
      model = Sketchup.active_model
      model.start_operation('SF Color', true)

      rgba = SF_COLORS[cat] || SF_DEFAULT_COLOR
      mat_name = "TO_SF_#{cat.gsub(/[\s\/]+/,'_')}"
      mat = model.materials[mat_name] || model.materials.add(mat_name)
      mat.color = Sketchup::Color.new(166, 227, 161)
      mat.alpha = 1.0

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
      pn = @last_part_name && !@last_part_name.empty? ? @last_part_name : nil
      grp.name = pn ? "TO_SF: #{pn} — #{cat} — #{'%.1f' % @total_sf} SF" : "TO_SF: #{cat} — #{'%.1f' % @total_sf} SF"

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
      grp.set_attribute('TakeoffMeasurement', 'part_name', @last_part_name || '')
      grp.set_attribute('TakeoffMeasurement', 'total_sf', @total_sf)
      grp.set_attribute('TakeoffMeasurement', 'face_count', @picked_faces.length)
      grp.set_attribute('TakeoffMeasurement', 'cost_code', @last_cc || '')
      grp.set_attribute('TakeoffMeasurement', 'note', @last_note || '')
      grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
      grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)

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
      pn = @last_part_name && !@last_part_name.empty? ? @last_part_name : nil
      display = pn ? "#{pn} — #{cat} — #{'%.1f' % @total_sf} SF" : "#{cat} — #{'%.1f' % @total_sf} SF"

      result = {
        entity_id: eid,
        tag: LF_TAG,
        definition_name: display,
        display_name: display,
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
          auto_subcategory: pn || '',
          element_type: cat,
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

      d = Dashboard.instance_variable_get(:@dialog)
      if d && d.visible?
        Dashboard.invalidate_measurement_cache
        Dashboard.send_data(TakeoffTool.scan_results, TakeoffTool.category_assignments, TakeoffTool.cost_code_assignments)
        Dashboard.send_measurement_data
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

  # ═══════════════════════════════════════════════════════════
  #  Edit SF Tool — click green (measured) faces to exclude
  #  them from an auto SF calculation. Works on the debug
  #  visualization painted by Scanner.debug_area_category.
  # ═══════════════════════════════════════════════════════════

  class EditSFTool

    def initialize(category)
      @category = category
      @ip = Sketchup::InputPoint.new
      @hover_face = nil
      @hover_xform = nil
      @hover_is_excluded = false
      @hover_is_new = false
      @edit_count = 0
    end

    def activate
      @current_total = compute_category_total
      Sketchup.status_text = "Edit SF [#{@category}]: Click green/blue to exclude (→ orange), orange/red to re-include (→ blue), bare to add (→ blue). Escape to finish."
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      @current_total = compute_category_total
      Sketchup.status_text = "Edit SF [#{@category}]: #{'%.1f' % @current_total} SF (#{@edit_count} edits). Escape to finish."
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      @ip.pick(view, x, y)
      @hover_face = nil
      @hover_xform = nil
      @hover_is_excluded = false
      @hover_is_new = false
      if @ip.valid? && @ip.face
        face = @ip.face
        mat = face.material
        if mat && (mat.name == 'FF_DEBUG_EXCLUDED' || mat.name == 'FF_EDIT_EXCLUDED')
          @hover_face = face
          @hover_xform = @ip.transformation
          @hover_is_excluded = true
          sf = face.area / 144.0
          view.tooltip = "Click to re-include: +#{'%.1f' % sf} SF"
        elsif mat && sf_face?(mat)
          @hover_face = face
          @hover_xform = @ip.transformation
          sf = face.area / 144.0
          view.tooltip = "Click to exclude: -#{'%.1f' % sf} SF"
        elsif face.is_a?(Sketchup::Face)
          @hover_face = face
          @hover_xform = @ip.transformation
          @hover_is_new = true
          sf = face.area / 144.0
          view.tooltip = "Click to add: +#{'%.1f' % sf} SF"
        end
      end
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return unless @hover_face && @hover_face.valid?

      face = @hover_face
      sf = face.area / 144.0
      model = Sketchup.active_model

      if @hover_is_excluded
        # RE-INCLUDE: orange → blue, ADD sf back to total
        model.start_operation('Include SF Face', true)
        face.material = get_edit_measured_mat(model)
        face.back_material = get_edit_measured_mat(model)
        model.commit_operation
        adjust_total(sf)

      elsif @hover_is_new
        # ADD: bare face → blue, ADD sf to total
        model.start_operation('Add SF Face', true)
        orig_mat_name = face.material ? face.material.name : ''
        face.set_attribute('FF_EditSF', 'original_mat', orig_mat_name)
        face.set_attribute('FF_EditSF', 'was_new', true)
        face.material = get_edit_measured_mat(model)
        face.back_material = get_edit_measured_mat(model)
        model.commit_operation
        adjust_total(sf)

      else
        # EXCLUDE: green/blue → red, SUBTRACT sf from total
        model.start_operation('Exclude SF Face', true)
        face.set_attribute('FF_EditSF', 'original_mat', face.material ? face.material.name : '')
        face.material = get_edit_excluded_mat(model)
        face.back_material = get_edit_excluded_mat(model)
        model.commit_operation
        adjust_total(-sf)
      end

      @edit_count += 1
      @current_total = compute_category_total
      Sketchup.status_text = "Edit SF [#{@category}]: #{'%.1f' % @current_total} SF (#{@edit_count} edits). Escape to finish."

      @hover_face = nil
      @hover_is_excluded = false
      @hover_is_new = false
      view.invalidate
    end

    def onKeyDown(key, repeat, flags, view)
      if key == 27 # Escape
        refresh_panel
        Sketchup.active_model.select_tool(nil)
      end
      false
    end

    def onCancel(reason, view)
      refresh_panel
      Sketchup.active_model.select_tool(nil)
    end

    def draw(view)
      return unless @hover_face && @hover_face.valid?
      begin
        mesh = @hover_face.mesh(0)
        pts = []
        (1..mesh.count_points).each do |i|
          pt = mesh.point_at(i)
          pts << (@hover_xform ? @hover_xform * pt : pt)
        end
        return if pts.length < 3
        if @hover_is_excluded
          view.drawing_color = Sketchup::Color.new(166, 227, 161, 100)
        elsif @hover_is_new
          view.drawing_color = Sketchup::Color.new(137, 180, 250, 100)
        else
          view.drawing_color = Sketchup::Color.new(243, 139, 168, 100)
        end
        view.draw(GL_POLYGON, pts)
      rescue
      end
    end

    def getExtents
      Geom::BoundingBox.new
    end

    private

    def sf_face?(mat)
      return false unless mat
      name = mat.name
      name == 'FF_DEBUG_MEASURED' || name == 'FF_EDIT_MEASURED' || name.start_with?('TO_SF_')
    end

    def get_edit_measured_mat(model)
      mat = model.materials['FF_EDIT_MEASURED'] || model.materials.add('FF_EDIT_MEASURED')
      mat.color = Sketchup::Color.new(116, 199, 236)  # Blue to distinguish from auto green
      mat.alpha = 1.0
      mat
    end

    def get_edit_excluded_mat(model)
      mat = model.materials['FF_EDIT_EXCLUDED'] || model.materials.add('FF_EDIT_EXCLUDED')
      mat.color = Sketchup::Color.new(250, 179, 135)  # Orange — distinct from auto red
      mat.alpha = 1.0
      mat
    end

    # Directly adjust area_sf on scan results for this category
    # AND update the total_sf attribute on any manual SF measurement groups
    def adjust_total(delta_sf)
      sr = TakeoffTool.scan_results || []
      ca = TakeoffTool.category_assignments || {}

      # Find scan results in this category
      cat_results = sr.select do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category]
        cat == @category
      end

      if cat_results.any?
        # Distribute the delta proportionally across entities
        total = cat_results.sum { |r| (r[:area_sf] || 0).to_f }
        if total > 0 && delta_sf.abs > 0.01
          factor = (total + delta_sf) / total
          cat_results.each do |r|
            r[:area_sf] = ((r[:area_sf] || 0) * factor).round(2)
          end
        elsif delta_sf > 0 && total == 0
          # Adding to a zero-total category — put it all on the first result
          cat_results.first[:area_sf] = delta_sf.round(2) if cat_results.first
        end
      end

      # Also update total_sf on any manual SF measurement groups for this category
      m = Sketchup.active_model
      return unless m
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        next unless grp.get_attribute('TakeoffMeasurement', 'type') == 'SF'
        next unless grp.get_attribute('TakeoffMeasurement', 'category') == @category
        old_total = (grp.get_attribute('TakeoffMeasurement', 'total_sf') || 0).to_f
        new_total = [old_total + delta_sf, 0.0].max
        grp.set_attribute('TakeoffMeasurement', 'total_sf', new_total.round(2))
        # Only adjust one group per click — the delta applies once
        break
      end
    end

    def compute_category_total
      sr = TakeoffTool.scan_results || []
      ca = TakeoffTool.category_assignments || {}
      total = 0.0
      sr.each do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category]
        next unless cat == @category
        total += (r[:area_sf] || 0).to_f
      end
      total
    end

    def refresh_panel
      rebuild_face_refs_for_category
      Dashboard.invalidate_measurement_cache rescue nil
      Dashboard.send_measurement_data rescue nil
      Dashboard.send_live_data rescue nil
    end

    def rebuild_face_refs_for_category
      m = Sketchup.active_model
      return unless m

      # Collect all currently-measured faces (green) in entities belonging to this category
      sr = TakeoffTool.scan_results || []
      ca = TakeoffTool.category_assignments || {}
      measured_faces = []

      sr.each do |r|
        cat = ca[r[:entity_id]] || r[:parsed][:auto_category]
        next unless cat == @category
        e = TakeoffTool.find_entity(r[:entity_id])
        next unless e && e.valid? && e.respond_to?(:definition)
        e.definition.entities.grep(Sketchup::Face).each do |f|
          fm = f.material
          next unless fm
          if fm.name == 'FF_DEBUG_MEASURED' || fm.name == 'FF_EDIT_MEASURED' || fm.name.start_with?('TO_SF_')
            measured_faces << f
          end
        end
      end

      # Find manual SF measurement groups for this category and rebuild their face_refs
      require 'json'
      m.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        next unless grp.get_attribute('TakeoffMeasurement', 'type') == 'SF'
        next unless grp.get_attribute('TakeoffMeasurement', 'category') == @category

        # Rebuild refs from currently measured faces
        refs = measured_faces.map do |f|
          pid = f.respond_to?(:persistent_id) ? f.persistent_id : nil
          parent = f.parent
          defn_name = if parent.is_a?(Sketchup::ComponentDefinition)
                        parent.name
                      else
                        '__model__'
                      end
          fidx = begin
            parent_ents = parent.is_a?(Sketchup::ComponentDefinition) ? parent.entities : m.entities
            parent_ents.grep(Sketchup::Face).index(f) || -1
          rescue
            -1
          end
          { 'pid' => pid, 'defn' => defn_name, 'fidx' => fidx }
        end

        new_total = measured_faces.sum { |f| f.area / 144.0 }.round(2)

        grp.set_attribute('TakeoffMeasurement', 'face_refs', JSON.generate(refs))
        grp.set_attribute('TakeoffMeasurement', 'face_count', measured_faces.length)
        grp.set_attribute('TakeoffMeasurement', 'total_sf', new_total)
        puts "EditSF: Rebuilt face_refs for #{@category}: #{measured_faces.length} faces, #{'%.1f' % new_total} SF"
      end
    end
  end

  def self.activate_edit_sf(category)
    Sketchup.active_model.select_tool(EditSFTool.new(category))
  end
end
