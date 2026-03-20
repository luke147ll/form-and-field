module TakeoffTool
  unless defined?(LF_TAG)
  LF_TAG = 'TO_Measurements'
  RIBBON_WIDTH = 1.5  # inches — width of the visual ribbon artifact

  LF_COLORS = {
    'Trim'        => [180, 140, 200, 160],
    'Fascia'      => [180, 160, 200, 160],
    'Gutters'     => [100, 180, 200, 160],
    'Flashing'    => [200, 160, 80, 160],
    'Soffit'      => [200, 180, 220, 160],
    'Baseboard'   => [140, 200, 140, 160],
    'Crown Mold'  => [220, 180, 140, 160],
    'Casing'      => [180, 200, 140, 160],
    'Countertops' => [200, 180, 160, 160],
    'Railing'     => [160, 160, 200, 160],
    'Drip Edge'   => [140, 180, 220, 160],
    'Casework'    => [180, 200, 140, 160],
    'Roofing'     => [150, 170, 210, 160],
    'Drywall'     => [249, 226, 175, 160],
    'Custom'      => [200, 200, 100, 160]
  }
  LF_DEFAULT_COLOR = [255, 100, 255, 160]

  LF_CATEGORIES = ['Trim','Fascia','Gutters','Flashing','Soffit','Baseboard',
    'Crown Mold','Casing','Countertops','Railing','Drip Edge',
    'Casework','Roofing','Drywall','Custom']

  PICK_DIALOG_CSS = <<~CSS.freeze
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: 'Segoe UI', system-ui, sans-serif;
      font-size: 13px;
      background: #1e1e2e;
      color: #cdd6f4;
      padding: 16px;
      overflow: hidden;
    }
    h1 {
      font-size: 14px;
      font-weight: 700;
      color: #cba6f7;
      text-transform: uppercase;
      letter-spacing: 1.5px;
      margin-bottom: 14px;
      padding-bottom: 8px;
      border-bottom: 2px solid #313244;
    }
    label {
      display: block;
      color: #a6adc8;
      font-size: 12px;
      margin-bottom: 4px;
      margin-top: 10px;
    }
    label:first-of-type { margin-top: 0; }
    input, select {
      width: 100%;
      padding: 8px 10px;
      background: #313244;
      color: #cdd6f4;
      border: 1px solid #585b70;
      border-radius: 6px;
      font-size: 13px;
      font-family: inherit;
    }
    input:focus, select:focus { outline: none; border-color: #89b4fa; }
    .buttons {
      display: flex;
      gap: 8px;
      margin-top: 16px;
      justify-content: flex-end;
    }
    .btn {
      padding: 8px 20px;
      border: none;
      border-radius: 6px;
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
      font-family: inherit;
    }
    .btn-ok { background: #cba6f7; color: #1e1e2e; }
    .btn-ok:hover { background: #b4befe; }
    .btn-cancel { background: #45475a; color: #cdd6f4; }
    .btn-cancel:hover { background: #585b70; }
  CSS
  end # unless defined?(LF_TAG)

  class MeasureLFTool

    def initialize(preset_category = nil, opts = {})
      @segments = [[]]
      @ip = Sketchup::InputPoint.new
      @ip_start = Sketchup::InputPoint.new
      @mouse_pt = nil
      @total_lf = 0.0
      @preset_category = preset_category
      @panel = nil
      @save_pending = false
      @lock_mode = :free
      @lock_z = nil
      @lock_xy = nil
      @part_link_id = opts[:part_link_id]  # derived part ID to link on save
      @part_link_label = opts[:label]      # label override for part-linked measurements
      @part_link_color = opts[:color]      # color override [r,g,b]
    end

    def activate
      reset_full
      open_panel
      update_status
    end

    def deactivate(view)
      close_panel
      reset_full
      Dashboard.invalidate_measurement_cache rescue nil
      Dashboard.send_measurement_data rescue nil
      Dashboard.send_live_data rescue nil
      MeasurementsPanel.send_data rescue nil
      view.invalidate
    end

    def resume(view)
      update_status
      view.invalidate
    end

    # ─── Mouse ───

    def onMouseMove(flags, x, y, view)
      return if @save_pending
      @ip.pick(view, x, y, @ip_start)
      if @ip.valid?
        @mouse_pt = apply_lock(@ip.position)
        view.tooltip = @ip.tooltip
      end
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return if @save_pending
      @ip.pick(view, x, y, @ip_start)
      return unless @ip.valid?

      # Auto-detect category from the first clicked entity
      if total_points == 0
        cat = detect_category_at(x, y, view)
        set_panel_category(cat) if cat
      end

      pt = apply_lock(@ip.position)
      chain = @segments.last

      if chain.empty? && @lock_mode != :free
        @lock_z = pt.z if @lock_mode == :horiz
        @lock_xy = [pt.x, pt.y] if @lock_mode == :vert
      end

      if chain.length > 0
        @total_lf += chain.last.distance(pt)
      end

      chain << pt
      @ip_start.copy!(@ip)

      update_vcb
      update_status
      update_panel
      view.invalidate
    end

    def onLButtonDoubleClick(flags, x, y, view)
      trigger_save if total_points >= 2
    end

    # ─── Right-click: start a new disconnected segment ───
    def onRButtonDown(flags, x, y, view)
      if @segments.last.length > 0
        @segments << []
        @ip_start = Sketchup::InputPoint.new
        @lock_z = nil
        @lock_xy = nil
        update_status
        update_panel
        view.invalidate
      end
    end

    def getMenu(menu, flags, x, y, view)
      menu.add_item("Start New Segment") { onRButtonDown(flags, x, y, view) }
      if total_points >= 2
        menu.add_item("Save (#{format_length(@total_lf)})") { trigger_save }
      end
      menu.add_item("Cancel") { cancel(view) }
      true
    end

    # ─── Keyboard ───

    def onKeyDown(key, repeat, flags, view)
      case key
      when 13
        trigger_save if total_points >= 2
      when 0x48 # H — toggle horizontal lock
        if @lock_mode == :horiz
          @lock_mode = :free
          @lock_z = nil
        else
          @lock_mode = :horiz
          @lock_z = @segments.last.last.z if @segments.last.length > 0
        end
        update_status
        view.invalidate
      when 0x56 # V — toggle vertical lock
        if @lock_mode == :vert
          @lock_mode = :free
          @lock_xy = nil
        else
          @lock_mode = :vert
          if @segments.last.length > 0
            lp = @segments.last.last
            @lock_xy = [lp.x, lp.y]
          end
        end
        update_status
        view.invalidate
      when 27
        cancel(view)
      end
    end

    def onCancel(reason, view)
      cancel(view)
    end

    # ─── Draw ───

    def draw(view)
      @segments.each do |chain|
        next if chain.length < 2
        chain.each_cons(2) do |a, b|
          view.drawing_color = Sketchup::Color.new(255, 80, 255)
          view.line_width = 3
          view.line_stipple = ''
          view.draw_line(a, b)
        end
      end

      pts = []
      @segments.each { |chain| chain.each { |p| pts << p } }
      if pts.length > 0
        view.draw_points(pts, 8, 2, Sketchup::Color.new(255, 200, 80))
      end

      chain = @segments.last
      if chain.length >= 1 && @mouse_pt
        view.drawing_color = Sketchup::Color.new(255, 80, 255, 128)
        view.line_width = 2
        view.line_stipple = '_'
        view.draw_line(chain.last, @mouse_pt)
        view.line_stipple = ''

        seg = chain.last.distance(@mouse_pt)
        running = @total_lf + seg
        mid = Geom::Point3d.linear_combination(0.5, chain.last, 0.5, @mouse_pt)
        screen = view.screen_coords(mid)
        view.draw_text(screen, "Seg: #{format_length(seg)}  Total: #{format_length(running)}",
          color: Sketchup::Color.new(255, 220, 100))
      end

      if pts.length > 0 && @total_lf > 0
        screen = view.screen_coords(pts.first)
        screen.y -= 20
        view.draw_text(screen, "Total: #{format_length(@total_lf)}",
          color: Sketchup::Color.new(100, 255, 100))
      end
    end

    def getExtents
      bb = Geom::BoundingBox.new
      @segments.each { |chain| chain.each { |p| bb.add(p) } }
      bb.add(@mouse_pt) if @mouse_pt
      bb
    end

    private

    # ─── Panel ───

    def open_panel
      all_cats = TakeoffTool.master_categories
      default_cat = @preset_category || @last_cat || 'Trim'
      cat_opts = all_cats.map { |c|
        sel = c == default_cat ? ' selected' : ''
        "<option value=\"#{c}\"#{sel}>#{c}</option>"
      }.join
      cat_opts += '<option value="__custom__">+ Custom...</option>'

      @panel = UI::HtmlDialog.new(
        dialog_title: "LF Measurement",
        width: 260, height: 440,
        left: 80, top: 200,
        style: UI::HtmlDialog::STYLE_UTILITY,
        resizable: false
      )

      lf_tool = self

      @panel.add_action_callback('save') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          cc  = data['cc'].to_s
          note = data['note'].to_s
          part_name = data['name'].to_s.strip
          lf_tool.send(:save_measurement, cat, cc, note, part_name) unless cat.empty?
        rescue => e
          puts "Takeoff LF: save error: #{e.message}"
        end
      end

      @panel.add_action_callback('cancel') do |_ctx|
        Sketchup.active_model.select_tool(nil)
      end

      @panel.set_on_closed do
        @panel = nil
        UI.start_timer(0) { Sketchup.active_model.select_tool(nil) }
      end

      @panel.set_html(lf_panel_html(cat_opts))
      @panel.show

      # Pre-fill name when launched from a derived part
      if @part_link_label && !@part_link_label.empty?
        safe = @part_link_label.gsub("'", "\\\\'")
        UI.start_timer(0.1) { @panel.execute_script("document.getElementById('name').value='#{safe}'") if @panel }
      end
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
      total_str = format_length(@total_lf)
      pts = total_points
      segs = @segments.select { |c| c.length >= 2 }.length
      @panel.execute_script("updateTotal(#{JSON.generate(total_str)},#{pts},#{segs})") rescue nil
    end

    def trigger_save
      return unless @panel && total_points >= 2
      @save_pending = true
      @panel.bring_to_front rescue nil
      @panel.execute_script("focusName()") rescue nil
    end

    def lf_panel_html(cat_options)
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
        <div class="hdr">LF Measurement</div>
        <div class="total-val" id="totalVal">0'-0"</div>
        <div class="total-detail" id="totalDetail">Click to start measuring</div>
        <div class="divider"></div>
        <label>Name</label>
        <input id="name" type="text" placeholder="e.g. Drip Edge, Crown Mold...">
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
        function updateTotal(totalStr,points,segments){
          document.getElementById('totalVal').textContent=totalStr;
          var d=points+' point'+(points!==1?'s':'');
          if(segments>1) d+=' \\u00b7 '+segments+' segment'+(segments!==1?'s':'');
          document.getElementById('totalDetail').textContent=d;
          document.getElementById('saveBtn').disabled=points<2;
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

    # ─── Helpers ───

    def total_points
      @segments.reduce(0) { |s, chain| s + chain.length }
    end

    def cancel(view)
      Sketchup.active_model.select_tool(nil)
    end

    def reset_full
      @segments = [[]]
      @mouse_pt = nil
      @total_lf = 0.0
      @save_pending = false
      @ip = Sketchup::InputPoint.new
      @ip_start = Sketchup::InputPoint.new
      @lock_z = nil
      @lock_xy = nil
      update_vcb
    end

    def apply_lock(pt)
      case @lock_mode
      when :horiz
        z = @lock_z || (@segments.last.length > 0 ? @segments.last.first.z : pt.z)
        Geom::Point3d.new(pt.x, pt.y, z)
      when :vert
        if @lock_xy
          Geom::Point3d.new(@lock_xy[0], @lock_xy[1], pt.z)
        else
          pt
        end
      else
        pt
      end
    end

    def update_vcb
      Sketchup.vcb_label = "Total LF"
      Sketchup.vcb_value = format_length(@total_lf)
    end

    def update_status
      n = total_points
      segs = @segments.select { |c| c.length >= 2 }.length
      lock = case @lock_mode
             when :horiz then " [H-LOCK]"
             when :vert  then " [V-LOCK]"
             else ""
             end
      if n == 0
        Sketchup.status_text = "LF Tool:#{lock} Click to start. H=horiz lock, V=vert lock. Right-click=new seg. Enter=save."
      elsif n == 1
        Sketchup.status_text = "LF Tool:#{lock} Click next point. H=toggle horiz, V=toggle vert."
      else
        seg_info = segs > 1 ? " (#{segs} segments)" : ""
        Sketchup.status_text = "LF Tool:#{lock} #{format_length(@total_lf)}#{seg_info} — Click to continue, Enter/Dbl-click to save."
      end
    end

    def format_length(inches)
      return "0'-0\"" if inches < 0.001
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

    # ─── Save ───

    def save_measurement(cat, cc, note, part_name = '')
      return if total_points < 2

      total_inches = 0.0
      @segments.each do |chain|
        chain.each_cons(2) { |a, b| total_inches += a.distance(b) }
      end
      total_ft = total_inches / 12.0

      TakeoffTool.add_custom_category(cat) unless TakeoffTool.master_categories.include?(cat)
      @last_cat = cat
      @last_cc = cc
      @last_note = note
      @last_part_name = part_name || ''

      # Set category measurement type to LF if not already set
      m = Sketchup.active_model
      existing_mt = m.get_attribute('TakeoffMeasurementTypes', cat) rescue nil
      m.set_attribute('TakeoffMeasurementTypes', cat, 'lf') if !existing_mt || existing_mt.empty?

      create_ribbon_artifact(cat, total_ft, total_inches)
      add_to_results(cat, total_ft, total_inches)

      Sketchup.status_text = "LF Tool: Saved #{format_length(total_inches)} of #{cat}. Click to start new measurement."
      reset_full
      update_panel
      Sketchup.active_model.active_view.invalidate
    end

    # ─── Create colored ribbon (thin face strip) for visibility ───

    def create_ribbon_artifact(cat, total_ft, total_inches)
      model = Sketchup.active_model
      model.start_operation('LF Measurement', true)

      tag = model.layers[LF_TAG] || model.layers.add(LF_TAG)

      grp = model.active_entities.add_group
      grp.layer = tag
      pn = @last_part_name && !@last_part_name.empty? ? @last_part_name : nil
      grp.name = pn ? "TO_LF: #{pn} — #{cat} — #{'%.1f' % total_ft} ft" : "TO_LF: #{cat} — #{'%.1f' % total_ft} ft"

      rgba = LF_COLORS[cat] || LF_DEFAULT_COLOR
      mat_name = "TO_LF_#{cat.gsub(/\s+/,'_')}"
      mat = model.materials[mat_name]
      unless mat
        mat = model.materials.add(mat_name)
        mat.color = Sketchup::Color.new(rgba[0], rgba[1], rgba[2])
        mat.alpha = (rgba[3] || 160) / 255.0
      end

      @segments.each do |chain|
        next if chain.length < 2
        chain.each_cons(2) do |a, b|
          add_ribbon_segment(grp.entities, a, b, mat)
        end
      end

      @segments.each do |chain|
        next if chain.length < 2
        chain.each_cons(2) do |a, b|
          e = grp.entities.add_line(a, b)
          e.material = mat if e
        end
      end

      grp.set_attribute('TakeoffMeasurement', 'type', 'LF')
      grp.set_attribute('TakeoffMeasurement', 'category', cat)
      grp.set_attribute('TakeoffMeasurement', 'part_name', @last_part_name || '')
      grp.set_attribute('TakeoffMeasurement', 'total_inches', total_inches)
      grp.set_attribute('TakeoffMeasurement', 'total_ft', total_ft)
      grp.set_attribute('TakeoffMeasurement', 'cost_code', @last_cc || '')
      grp.set_attribute('TakeoffMeasurement', 'note', @last_note || '')
      grp.set_attribute('TakeoffMeasurement', 'segment_count', @segments.select{|c| c.length >= 2}.length)
      grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
      grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      grp.set_attribute('TakeoffMeasurement', 'material_name', mat_name)
      require 'json'
      grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate(rgba))

      # Mark as child measurement if linked to a derived part
      if @part_link_id
        grp.set_attribute('TakeoffMeasurement', 'part_link', @part_link_id)
      end

      TakeoffTool.entity_registry[grp.entityID] = grp

      model.commit_operation
      @last_grp_eid = grp.entityID

      # Link measurement group to derived part
      if @part_link_id
        begin
          dp_json = model.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          if parts[@part_link_id]
            parts[@part_link_id]['sourceEid'] = grp.entityID
            model.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
          end
        rescue => e
          puts "Takeoff: LF poly part link error: #{e.message}"
        end
      end

      grp
    end

    def add_ribbon_segment(entities, pt_a, pt_b, mat)
      dir = pt_b.vector_to(pt_a).reverse
      return if dir.length < 0.001

      up = Geom::Vector3d.new(0, 0, 1)
      perp = dir.cross(up)

      if perp.length < 0.001
        perp = dir.cross(Geom::Vector3d.new(1, 0, 0))
      end

      return if perp.length < 0.001
      perp.normalize!
      offset = perp.transform(Geom::Transformation.scaling(RIBBON_WIDTH / 2.0))

      p1 = pt_a.offset(offset)
      p2 = pt_a.offset(offset.reverse)
      p3 = pt_b.offset(offset.reverse)
      p4 = pt_b.offset(offset)

      begin
        face = entities.add_face(p1, p2, p3, p4)
        if face
          face.material = mat
          face.back_material = mat
        end
      rescue => e
        puts "Takeoff LF: ribbon face failed: #{e.message}"
      end
    end

    def add_to_results(cat, total_ft, total_inches)
      seg_count = @segments.select{|c| c.length >= 2}.length
      pn = @last_part_name && !@last_part_name.empty? ? @last_part_name : nil
      display = pn ? "#{pn} — #{cat} — #{'%.1f' % total_ft} LF" : "#{cat} — #{'%.1f' % total_ft} LF"

      result = {
        entity_id: @last_grp_eid,
        tag: LF_TAG,
        definition_name: display,
        display_name: display,
        material: '',
        is_solid: false,
        instance_count: 1,
        volume_ft3: 0.0,
        volume_bf: 0.0,
        area_sf: 0.0,
        linear_ft: total_ft,
        bb_width_in: 0, bb_height_in: 0, bb_depth_in: 0,
        ifc_type: nil,
        warnings: [],
        parsed: {
          auto_category: cat,
          auto_subcategory: pn || '',
          element_type: cat,
          function: 'LF',
          material: @last_note || '',
          thickness: '',
          size_nominal: '',
          revit_id: nil
        },
        source: :manual_lf
      }

      TakeoffTool.scan_results << result

      if @last_grp_eid
        TakeoffTool.category_assignments[@last_grp_eid] = cat
        if @last_cc && !@last_cc.empty?
          TakeoffTool.cost_code_assignments[@last_grp_eid] = @last_cc
        end
      end

      d = Dashboard.instance_variable_get(:@dialog)
      if d && d.visible?
        Dashboard.send_data(TakeoffTool.scan_results, TakeoffTool.category_assignments, TakeoffTool.cost_code_assignments)
      end

      puts "Takeoff LF: Added #{cat} #{'%.1f' % total_ft} ft (entity #{@last_grp_eid})"
    end
  end

  # ─── Load manual measurements from model on scan ───
  def self.load_manual_measurements
    model = Sketchup.active_model
    return 0 unless model
    count = 0

    model.active_entities.grep(Sketchup::Group).each do |grp|
      mtype = grp.get_attribute('TakeoffMeasurement', 'type')
      next unless mtype

      cat = grp.get_attribute('TakeoffMeasurement', 'category') || 'Custom'
      total_ft = grp.get_attribute('TakeoffMeasurement', 'total_ft') || 0
      total_sf = grp.get_attribute('TakeoffMeasurement', 'total_sf') || 0
      cc = grp.get_attribute('TakeoffMeasurement', 'cost_code') || ''
      note = grp.get_attribute('TakeoffMeasurement', 'note') || ''
      seg_count = grp.get_attribute('TakeoffMeasurement', 'segment_count') || 1
      face_count = grp.get_attribute('TakeoffMeasurement', 'face_count') || 0
      highlights_visible = grp.get_attribute('TakeoffMeasurement', 'highlights_visible')

      next if mtype == 'BENCHMARK'
      next if mtype == 'NOTE'

      part_name = grp.get_attribute('TakeoffMeasurement', 'part_name') || ''
      vol_cf = 0

      if mtype == 'SF'
        display = part_name.empty? ? "#{cat} — #{'%.1f' % total_sf} SF" : "#{part_name} — #{cat} — #{'%.1f' % total_sf} SF"
        lf_val = 0.0
        sf_val = total_sf
      elsif mtype == 'BOX'
        w_in = grp.get_attribute('TakeoffMeasurement', 'width_in') || 0
        d_in = grp.get_attribute('TakeoffMeasurement', 'depth_in') || 0
        h_in = grp.get_attribute('TakeoffMeasurement', 'height_in') || 0
        vol_cf = grp.get_attribute('TakeoffMeasurement', 'volume_cf') || 0
        total_sf_val = grp.get_attribute('TakeoffMeasurement', 'total_sf') || 0
        perim_lf = grp.get_attribute('TakeoffMeasurement', 'perimeter_lf') || 0
        display = part_name.empty? ? "#{cat} — #{format_box_dim(w_in)} x #{format_box_dim(d_in)} x #{format_box_dim(h_in)}" : "#{part_name} — #{cat} — #{'%.1f' % vol_cf} CF"
        lf_val = perim_lf
        sf_val = total_sf_val
      elsif mtype == 'ELEV'
        elev_label = grp.get_attribute('TakeoffMeasurement', 'elevation_label') || ''
        display = elev_label
        lf_val = 0.0
        sf_val = 0.0
      else
        display = part_name.empty? ? "#{cat} — #{'%.1f' % total_ft} LF" : "#{part_name} — #{cat} — #{'%.1f' % total_ft} LF"
        lf_val = total_ft
        sf_val = 0.0
      end

      el_type = mtype == 'ELEV' ? 'Elevation Tag' : cat
      src = case mtype
            when 'SF' then :manual_sf
            when 'BOX' then :manual_box
            when 'ELEV' then :elevation_tag
            else :manual_lf
            end

      result = {
        entity_id: grp.entityID,
        tag: mtype == 'ELEV' ? (defined?(ELEV_TAG) ? ELEV_TAG : 'FF_Elevation_Tags') : LF_TAG,
        definition_name: display,
        display_name: display,
        material: '',
        is_solid: (mtype == 'BOX'),
        instance_count: 1,
        volume_ft3: vol_cf,
        volume_bf: 0.0,
        area_sf: sf_val,
        linear_ft: lf_val,
        bb_width_in: 0, bb_height_in: 0, bb_depth_in: 0,
        ifc_type: nil,
        warnings: [],
        parsed: {
          auto_category: cat,
          auto_subcategory: part_name.empty? ? '' : part_name,
          element_type: el_type,
          function: mtype,
          material: note,
          thickness: '',
          size_nominal: '',
          revit_id: nil
        },
        source: src
      }

      @entity_registry[grp.entityID] = grp
      @scan_results << result
      @category_assignments[grp.entityID] = cat
      @cost_code_assignments[grp.entityID] = cc if cc && !cc.empty?
      count += 1
    end

    puts "Takeoff: Loaded #{count} manual measurements from model" if count > 0
    count
  end

  def self.format_box_dim(inches)
    return "0'-0\"" if inches.nil? || inches.to_f < 0.001
    inches = inches.to_f.abs
    ft = (inches / 12.0).floor
    ins = inches - (ft * 12)
    whole = ins.floor
    "#{ft}'-#{whole}\""
  end

  def self.activate_lf_tool
    Sketchup.active_model.select_tool(MeasureLFTool.new)
  end

  def self.activate_lf_tool_for_category(cat)
    Sketchup.active_model.select_tool(MeasureLFTool.new(cat))
  end

  # ═══════════════════════════════════════════════════════════
  #  MeasureLFFaceTool — click model faces to measure perimeter.
  #  Flood-fills coplanar neighbors, extracts boundary, creates
  #  ribbon geometry. Same UX pattern as MeasureSFTool.
  # ═══════════════════════════════════════════════════════════

  class MeasureLFFaceTool
    FLOOD_ANGLE_TOL = 5.0   # degrees — coplanar threshold
    OFFSET_DIST     = 0.5   # inches — offset toward camera
    LF_RIBBON_WIDTH = 1.5   # inches — ribbon visual width
    DIR_HORIZ_Z_MAX = 0.342 # sin(20°) — Z ratio below this = horizontal edge
    DIR_VERT_Z_MIN  = 0.940 # cos(20°) — Z ratio above this = vertical edge
    VK_LEFT = 37; VK_UP = 38; VK_RIGHT = 39; VK_DOWN = 40
    DIR_LABELS = {
      bottom: "\u2193 BOTTOM", top: "\u2191 TOP",
      vert_left: "\u2190 VERT-L", vert_right: "\u2192 VERT-R", all: 'ALL'
    }.freeze

    def initialize(category, opts = {})
      @category = category
      @group_eid = opts[:group_eid]
      @label = opts[:label] || category
      @color_rgb = opts[:color] || [166, 227, 161]
      @part_link_id = opts[:part_link_id] # derived part ID to link on deactivate
      @hover_face = nil
      @hover_xform = nil
      @hover_cluster = nil
      @hover_boundary = nil
      @hover_normal = nil
      @hover_segments = nil
      @hover_lf = 0.0
      @measurement_group = nil
      @total_lf = 0.0
      @edge_count = 0
      @dir_filter = :bottom  # :bottom, :top, :vert_left, :vert_right, :all
    end

    def activate
      find_or_create_group
      recompute_totals
      update_status
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
          puts "Takeoff: LF part link error: #{e.message}"
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
      update_status
      view.invalidate
    end

    # ─── Mouse ───

    def onMouseMove(flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)

      face = nil
      xform = nil

      ph.count.times do |i|
        leaf = ph.leaf_at(i)
        if leaf.is_a?(Sketchup::Face)
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
        _centroid, @hover_normal = compute_best_fit_plane(@hover_cluster, @hover_xform)
        @hover_segments = filter_segments(@hover_boundary)
        @hover_lf = compute_segments_lf(@hover_segments)
        mode = DIR_LABELS[@dir_filter] || 'ALL'
        view.tooltip = "#{mode}: #{'%.1f' % @hover_lf} LF (#{@hover_segments.length} edges)"
        view.invalidate
      elsif !face && @hover_face
        @hover_face = nil
        @hover_xform = nil
        @hover_cluster = nil
        @hover_boundary = nil
        @hover_normal = nil
        @hover_segments = nil
        @hover_lf = 0.0
        view.invalidate
      end
    end

    def onLButtonDown(flags, x, y, view)
      return unless @hover_face && @hover_cluster && @hover_boundary
      return unless @hover_segments && @hover_segments.length > 0

      model = Sketchup.active_model
      model.start_operation('Add LF Segment', false)

      begin
        # Compute best-fit plane for offset
        centroid, normal = compute_best_fit_plane(@hover_cluster, @hover_xform)
        return model.abort_operation unless centroid && normal

        find_or_create_group unless @measurement_group && @measurement_group.valid?
        mat = get_lf_material(model)

        # Create ribbon for each filtered segment
        @hover_segments.each do |pt_a, pt_b|
          off = project_and_offset([pt_a, pt_b], centroid, normal, view)
          next if off.length < 2
          add_ribbon_segment(@measurement_group.entities, off[0], off[1], mat, normal)
        end

        recompute_totals
        update_group_attributes
        model.commit_operation
        update_status
      rescue => e
        model.abort_operation
        puts "MeasureLFFace error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      end

      @hover_face = nil
      @hover_cluster = nil
      @hover_boundary = nil
      @hover_normal = nil
      @hover_segments = nil
      @hover_lf = 0.0
      view.invalidate
    end

    def enableVCB?
      false
    end

    def onKeyDown(key, repeat, flags, view)
      case key
      when 27  # Escape
        Sketchup.active_model.select_tool(nil)
        return true
      when 40  # Down arrow
        @dir_filter = @dir_filter == :bottom ? :all : :bottom
        refresh_hover(view)
        return true
      when 38  # Up arrow
        @dir_filter = @dir_filter == :top ? :all : :top
        refresh_hover(view)
        return true
      when 37  # Left arrow
        @dir_filter = @dir_filter == :vert_left ? :all : :vert_left
        refresh_hover(view)
        return true
      when 39  # Right arrow
        @dir_filter = @dir_filter == :vert_right ? :all : :vert_right
        refresh_hover(view)
        return true
      end
      false
    end

    def onCancel(reason, view)
      Sketchup.active_model.select_tool(nil)
    end

    def draw(view)
      begin
        r, g, b = @color_rgb

        # Draw dimmed full boundary when filtering so the user sees the whole outline
        if @dir_filter != :all && @hover_boundary && @hover_boundary.length >= 2
          view.line_width = 1
          view.drawing_color = Sketchup::Color.new(r, g, b, 40)
          loop_pts = @hover_boundary + [@hover_boundary.first]
          view.draw(GL_LINE_STRIP, loop_pts)
        end

        # Draw active filtered segments in bright color
        if @hover_segments && @hover_segments.length > 0
          view.line_width = 4
          view.drawing_color = Sketchup::Color.new(r, g, b, 220)
          pts = @hover_segments.flat_map { |a, b_pt| [a, b_pt] }
          view.draw(GL_LINES, pts)

          # Endpoints
          uniq_pts = []
          seen = {}
          pts.each do |p|
            k = "#{p.x.round(2)}_#{p.y.round(2)}_#{p.z.round(2)}"
            unless seen[k]
              uniq_pts << p
              seen[k] = true
            end
          end
          view.draw_points(uniq_pts, 8, 2, Sketchup::Color.new(r, g, b))
        end

        # Draw mode badge at screen top-left
        mode = DIR_LABELS[@dir_filter] || 'ALL'
        view.drawing_color = Sketchup::Color.new(r, g, b)
        pt2d = Geom::Point3d.new(14, view.vpheight - 28, 0)
        view.draw_text(pt2d, "LF Face: #{mode}", size: 14, bold: true, color: Sketchup::Color.new(r, g, b))
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

    # ─── Flood Fill (same as MeasureSFTool) ───

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

    # ─── Boundary Extraction (same as MeasureSFTool) ───

    def extract_outer_boundary(cluster, xform)
      return [] if cluster.empty?

      if cluster.length == 1
        return cluster[0].outer_loop.vertices.map { |v| xform * v.position }
      end

      cluster_ids = {}
      cluster.each { |f| cluster_ids[f.entityID] = true }

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

    # ─── Plane Projection (same as MeasureSFTool) ───

    def compute_best_fit_plane(cluster, xform)
      total_area = 0.0
      wx = 0.0; wy = 0.0; wz = 0.0
      cx = 0.0; cy = 0.0; cz = 0.0

      cluster.each do |face|
        area = face.area
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
        diff = pt - plane_pt
        dist_to_plane = diff.x * plane_normal.x + diff.y * plane_normal.y + diff.z * plane_normal.z
        projected = Geom::Point3d.new(
          pt.x - dist_to_plane * plane_normal.x,
          pt.y - dist_to_plane * plane_normal.y,
          pt.z - dist_to_plane * plane_normal.z
        )
        Geom::Point3d.new(
          projected.x + offset_vec.x,
          projected.y + offset_vec.y,
          projected.z + offset_vec.z
        )
      end
    end

    # ─── Direction Filtering + Perimeter ───

    def filter_segments(boundary_pts)
      return [] if boundary_pts.nil? || boundary_pts.length < 2
      pairs = boundary_pts.each_cons(2).to_a
      pairs << [boundary_pts.last, boundary_pts.first] if boundary_pts.length >= 3

      return pairs if @dir_filter == :all

      n = boundary_pts.length.to_f
      # Centroid for top/bottom and left/right splits
      cx = boundary_pts.sum { |p| p.x } / n
      cy = boundary_pts.sum { |p| p.y } / n
      cz = boundary_pts.sum { |p| p.z } / n

      # Wall horizontal axis for left/right vertical split
      # normal.cross([0,0,1]) = [normal.y, -normal.x, 0]
      wall_horiz = nil
      if @hover_normal && (@dir_filter == :vert_left || @dir_filter == :vert_right)
        wh = Geom::Vector3d.new(@hover_normal.y, -@hover_normal.x, 0)
        if wh.length > 0.001
          wh.normalize!
          wall_horiz = wh
        end
      end

      pairs.select do |pt_a, pt_b|
        len = pt_a.distance(pt_b)
        next false if len < 0.001
        dz = (pt_b.z - pt_a.z).abs
        z_ratio = dz / len

        case @dir_filter
        when :bottom
          edge_z = (pt_a.z + pt_b.z) / 2.0
          z_ratio < DIR_HORIZ_Z_MAX && edge_z <= cz
        when :top
          edge_z = (pt_a.z + pt_b.z) / 2.0
          z_ratio < DIR_HORIZ_Z_MAX && edge_z >= cz
        when :vert_left
          next false unless z_ratio > DIR_VERT_Z_MIN
          if wall_horiz
            mid_x = (pt_a.x + pt_b.x) / 2.0 - cx
            mid_y = (pt_a.y + pt_b.y) / 2.0 - cy
            proj = mid_x * wall_horiz.x + mid_y * wall_horiz.y
            proj <= 0
          else
            true  # fallback: include all vertical if no wall axis
          end
        when :vert_right
          next false unless z_ratio > DIR_VERT_Z_MIN
          if wall_horiz
            mid_x = (pt_a.x + pt_b.x) / 2.0 - cx
            mid_y = (pt_a.y + pt_b.y) / 2.0 - cy
            proj = mid_x * wall_horiz.x + mid_y * wall_horiz.y
            proj >= 0
          else
            true
          end
        end
      end
    end

    def compute_segments_lf(segments)
      return 0.0 if segments.nil? || segments.empty?
      segments.sum { |a, b| a.distance(b) } / 12.0
    end

    def refresh_hover(view)
      if @hover_boundary && @hover_boundary.length >= 2
        @hover_segments = filter_segments(@hover_boundary)
        @hover_lf = compute_segments_lf(@hover_segments)
      end
      update_status
      view.invalidate
    end

    def update_status
      display = @label != @category ? "#{@category} / #{@label}" : @category
      mode = DIR_LABELS[@dir_filter] || 'ALL'
      Sketchup.status_text = "LF Face [#{display}] #{mode}: #{'%.1f' % @total_lf} LF (#{@edge_count} segs) | \u2193Bottom \u2191Top \u2190Vert-L \u2192Vert-R | Esc=done"
    end

    # ─── Ribbon Geometry ───

    def add_ribbon_segment(entities, pt_a, pt_b, mat, plane_normal)
      dir = pt_b - pt_a
      return if dir.length < 0.001

      # Use the plane normal to compute a perpendicular that lies IN the plane
      perp = dir.cross(plane_normal)
      if perp.length < 0.001
        # Fallback: try world up
        perp = dir.cross(Geom::Vector3d.new(0, 0, 1))
        perp = dir.cross(Geom::Vector3d.new(1, 0, 0)) if perp.length < 0.001
      end
      return if perp.length < 0.001
      perp.normalize!

      half_w = LF_RIBBON_WIDTH / 2.0
      offset = Geom::Vector3d.new(perp.x * half_w, perp.y * half_w, perp.z * half_w)

      p1 = Geom::Point3d.new(pt_a.x + offset.x, pt_a.y + offset.y, pt_a.z + offset.z)
      p2 = Geom::Point3d.new(pt_a.x - offset.x, pt_a.y - offset.y, pt_a.z - offset.z)
      p3 = Geom::Point3d.new(pt_b.x - offset.x, pt_b.y - offset.y, pt_b.z - offset.z)
      p4 = Geom::Point3d.new(pt_b.x + offset.x, pt_b.y + offset.y, pt_b.z + offset.z)

      begin
        face = entities.add_face(p1, p2, p3, p4)
        if face
          face.material = mat
          face.back_material = mat
        end
      rescue => e
        puts "LFFace: ribbon segment failed: #{e.message}"
      end
    end

    # ─── Material ───

    def get_lf_material(model)
      r, g, b = @color_rgb
      eid = @measurement_group ? @measurement_group.entityID : 0
      mat_name = "FF_LF_#{eid}"
      mat = model.materials[mat_name] || model.materials.add(mat_name)
      mat.color = Sketchup::Color.new(r, g, b)
      mat.alpha = 0.7
      mat
    end

    # ─── Group Management ───

    def find_or_create_group
      m = Sketchup.active_model
      return unless m

      if @group_eid
        grp = TakeoffTool.find_entity(@group_eid)
        if grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'LF'
          @measurement_group = grp
          @label = grp.get_attribute('TakeoffMeasurement', 'label') || @label
          return
        end
      end

      require 'json'
      tag_name = 'TO_Measurements'
      tag = m.layers[tag_name] || m.layers.add(tag_name)
      r, g, b = @color_rgb

      @measurement_group = m.active_entities.add_group
      @measurement_group.layer = tag
      @measurement_group.name = "TO_LF: #{@label} — 0.0 LF"
      @measurement_group.set_attribute('TakeoffMeasurement', 'type', 'LF')
      @measurement_group.set_attribute('TakeoffMeasurement', 'category', @category)
      @measurement_group.set_attribute('TakeoffMeasurement', 'label', @label)
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_ft', 0.0)
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_inches', 0.0)
      @measurement_group.set_attribute('TakeoffMeasurement', 'segment_count', 0)
      @measurement_group.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
      @measurement_group.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
      @measurement_group.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([r, g, b, 179]))
      @measurement_group.set_attribute('TakeoffMeasurement', 'material_name', "FF_LF_#{@measurement_group.entityID}")

      # Mark as child measurement if linked to a derived part
      if @part_link_id
        @measurement_group.set_attribute('TakeoffMeasurement', 'part_link', @part_link_id)
      end

      TakeoffTool.entity_registry[@measurement_group.entityID] = @measurement_group
      TakeoffTool.invalidate_entity_cache
    end

    def recompute_totals
      if @measurement_group && @measurement_group.valid?
        edges = @measurement_group.entities.grep(Sketchup::Edge)
        faces = @measurement_group.entities.grep(Sketchup::Face)
        # Each ribbon segment creates 4 edges + 1 face. Count faces as segments.
        @edge_count = faces.length
        # Sum unique edge lengths along the ribbon center lines
        # Each ribbon face has 2 long edges (the measurement) and 2 short edges (the width).
        # The total LF = sum of long edge lengths / 2 (each measured twice).
        # Simpler: sum face areas / ribbon_width gives total length.
        total_inches = 0.0
        faces.each do |f|
          # Each ribbon face is a rectangle: length × width.
          # area / width = length
          total_inches += f.area / LF_RIBBON_WIDTH
        end
        @total_lf = (total_inches / 12.0).round(2)
      else
        @edge_count = 0
        @total_lf = 0.0
      end
    end

    def update_group_attributes
      return unless @measurement_group && @measurement_group.valid?
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_ft', @total_lf)
      @measurement_group.set_attribute('TakeoffMeasurement', 'total_inches', (@total_lf * 12.0).round(2))
      @measurement_group.set_attribute('TakeoffMeasurement', 'segment_count', @edge_count)
      @measurement_group.name = "TO_LF: #{@label} — #{'%.1f' % @total_lf} LF"
      @measurement_group.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
    end
  end

  # ─── LF Face Tool entry points ───

  def self.activate_lf_face_tool_for_category(cat)
    Sketchup.active_model.select_tool(MeasureLFFaceTool.new(cat))
  end

  def self.activate_lf_face_tool_new(category, label, color_rgb)
    Sketchup.active_model.select_tool(MeasureLFFaceTool.new(category, label: label, color: color_rgb))
  end

  def self.activate_lf_face_tool_for_group(group_eid, category)
    Sketchup.active_model.select_tool(MeasureLFFaceTool.new(category, group_eid: group_eid.to_i))
  end

  def self.update_lf_label(group_eid, new_label)
    grp = find_entity(group_eid.to_i)
    return unless grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'LF'
    m = Sketchup.active_model
    m.start_operation('Rename LF Measurement', true)
    grp.set_attribute('TakeoffMeasurement', 'label', new_label)
    total = grp.get_attribute('TakeoffMeasurement', 'total_ft') || 0
    grp.name = "TO_LF: #{new_label} — #{'%.1f' % total} LF"
    m.commit_operation
  end

  def self.update_lf_color(group_eid, color_rgb)
    grp = find_entity(group_eid.to_i)
    return unless grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'LF'
    m = Sketchup.active_model
    require 'json'
    m.start_operation('Change LF Color', true)
    grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([color_rgb[0], color_rgb[1], color_rgb[2], 179]))
    r, g, b = color_rgb
    mat_name = "FF_LF_#{grp.entityID}"
    mat = m.materials[mat_name] || m.materials.add(mat_name)
    mat.color = Sketchup::Color.new(r, g, b)
    mat.alpha = 0.7
    grp.entities.grep(Sketchup::Face).each do |face|
      face.material = mat
      face.back_material = mat
    end
    m.commit_operation
  end
end
