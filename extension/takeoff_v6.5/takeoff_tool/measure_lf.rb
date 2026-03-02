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

    def initialize(preset_category = nil)
      @segments = [[]]    # Array of arrays of Point3d — each sub-array is a connected chain
      @ip = Sketchup::InputPoint.new
      @ip_start = Sketchup::InputPoint.new
      @mouse_pt = nil
      @total_lf = 0.0
      @preset_category = preset_category
      @dialog_open = false
    end

    def activate
      reset_full
      update_status
    end

    def deactivate(view)
      @pick_dlg.close if @pick_dlg rescue nil
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
      @ip.pick(view, x, y, @ip_start)
      @mouse_pt = @ip.position if @ip.valid?
      view.tooltip = @ip.tooltip if @ip.valid?
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return if @dialog_open
      @ip.pick(view, x, y, @ip_start)
      return unless @ip.valid?

      pt = @ip.position
      chain = @segments.last

      # Add segment length to total
      if chain.length > 0
        @total_lf += chain.last.distance(pt)
      end

      chain << pt
      @ip_start.copy!(@ip)

      update_vcb
      update_status
      view.invalidate
    end

    def onLButtonDoubleClick(flags, x, y, view)
      return if @dialog_open
      finish_measurement(view) if total_points >= 2
    end

    # ─── Right-click: start a new disconnected segment ───
    def onRButtonDown(flags, x, y, view)
      # Only start new segment if current chain has points
      if @segments.last.length > 0
        @segments << []
        @ip_start = Sketchup::InputPoint.new
        Sketchup.status_text = "LF Tool: New segment started. Click to place first point. Total so far: #{format_length(@total_lf)}"
        view.invalidate
      end
    end

    def getMenu(menu, flags, x, y, view)
      # Suppress default context menu — we handle right-click for new segment
      menu.add_item("Start New Segment") { onRButtonDown(flags, x, y, view) }
      if total_points >= 2
        menu.add_item("Finish (#{format_length(@total_lf)})") { finish_measurement(view) }
      end
      menu.add_item("Cancel") { cancel(view) }
      true  # return true to show our custom menu
    end

    # ─── Keyboard ───

    def onKeyDown(key, repeat, flags, view)
      case key
      when 13 # Enter — finish
        finish_measurement(view) if total_points >= 2
      end
      # Escape (27) not handled — SketchUp natively pops the tool, triggering deactivate
    end

    # ─── Draw ───

    def draw(view)
      # Draw all completed segments
      @segments.each do |chain|
        next if chain.length < 2
        chain.each_cons(2) do |a, b|
          view.drawing_color = Sketchup::Color.new(255, 80, 255)
          view.line_width = 3
          view.line_stipple = ''
          view.draw_line(a, b)
        end
      end

      # Draw all placed points
      all_pts = @segments.flatten
      # flatten doesn't work on Point3d arrays, collect them
      pts = []
      @segments.each { |chain| chain.each { |p| pts << p } }
      if pts.length > 0
        view.draw_points(pts, 8, 2, Sketchup::Color.new(255, 200, 80))
      end

      # Draw rubber-band to cursor (hidden while save dialog is open)
      chain = @segments.last
      if chain.length >= 1 && @mouse_pt && !@dialog_open
        view.drawing_color = Sketchup::Color.new(255, 80, 255, 128)
        view.line_width = 2
        view.line_stipple = '_'
        view.draw_line(chain.last, @mouse_pt)
        view.line_stipple = ''

        # Show measurements near cursor
        seg = chain.last.distance(@mouse_pt)
        running = @total_lf + seg
        mid = Geom::Point3d.linear_combination(0.5, chain.last, 0.5, @mouse_pt)
        screen = view.screen_coords(mid)
        view.draw_text(screen, "Seg: #{format_length(seg)}  Total: #{format_length(running)}",
          color: Sketchup::Color.new(255, 220, 100))
      end

      # Show total near first point if we have measurements
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
      @ip = Sketchup::InputPoint.new
      @ip_start = Sketchup::InputPoint.new
      update_vcb
    end

    def update_vcb
      Sketchup.vcb_label = "Total LF"
      Sketchup.vcb_value = format_length(@total_lf)
    end

    def update_status
      n = total_points
      segs = @segments.select { |c| c.length >= 2 }.length
      if n == 0
        Sketchup.status_text = "LF Tool: Click to start. Right-click for new segment. Enter to finish. Esc to cancel."
      elsif n == 1
        Sketchup.status_text = "LF Tool: Click next point."
      else
        seg_info = segs > 1 ? " (#{segs} segments)" : ""
        Sketchup.status_text = "LF Tool: #{format_length(@total_lf)}#{seg_info} — Click to continue, Right-click for new segment, Enter/Dbl-click to finish, Esc to cancel."
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

    # ─── Finish and create artifact ───

    def finish_measurement(view)
      return if total_points < 2

      total_inches = 0.0
      @segments.each do |chain|
        chain.each_cons(2) { |a, b| total_inches += a.distance(b) }
      end
      total_ft = total_inches / 12.0
      saved_segments = @segments.map { |c| c.dup }
      lf_tool = self

      default_cat = @preset_category || @last_cat || 'Trim'
      cat_options = LF_CATEGORIES.map { |c|
        sel = c == default_cat ? ' selected' : ''
        "<option value=\"#{c}\"#{sel}>#{c}</option>"
      }.join

      html = <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <style>#{PICK_DIALOG_CSS}</style></head><body>
        <h1>LF Measurement &mdash; #{'%.1f' % total_ft} ft</h1>
        <label>Category</label>
        <select id="cat">#{cat_options}</select>
        <label>Cost Code (optional)</label>
        <input id="cc" type="text" value="#{(@last_cc || '').gsub('"', '&quot;')}">
        <label>Note (optional)</label>
        <input id="note" type="text" value="">
        <div class="buttons">
          <button class="btn btn-cancel" onclick="sketchup.cancel()">Cancel</button>
          <button class="btn btn-ok" onclick="sketchup.ok(JSON.stringify({cat:document.getElementById('cat').value,cc:document.getElementById('cc').value,note:document.getElementById('note').value}))">OK</button>
        </div>
        <script>document.addEventListener('keydown',function(e){if(e.key==='Escape')sketchup.cancel();});</script>
        </body></html>
      HTML

      @pick_dlg.close if @pick_dlg rescue nil
      @pick_dlg = UI::HtmlDialog.new(
        dialog_title: "LF Measurement",
        preferences_key: "TakeoffLFPick",
        width: 320, height: 340,
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
            lf_tool.send(:on_lf_ok, cat, cc, note,
                          total_ft, total_inches, saved_segments, view)
          end
        rescue => e
          puts "Takeoff LF: OK callback error: #{e.message}"
        end
      end

      @pick_dlg.add_action_callback('cancel') do |_ctx|
        @pick_dlg.close rescue nil
        @dialog_open = false
        Sketchup.status_text = "LF Tool: Cancelled. Click to start a new measurement."
        lf_tool.send(:reset_full)
        view.invalidate
      end

      @dialog_open = true
      @mouse_pt = nil
      @pick_dlg.set_html(html)
      @pick_dlg.show
    end

    def on_lf_ok(cat, cc, note, total_ft, total_inches, saved_segments, view)
      @dialog_open = false
      @last_cat = cat
      @last_cc = cc
      @last_note = note
      orig = @segments
      @segments = saved_segments
      create_ribbon_artifact(cat, total_ft, total_inches)
      add_to_results(cat, total_ft, total_inches)
      @segments = orig
      Sketchup.status_text = "LF Tool: Saved #{format_length(total_inches)} of #{cat}. Click to start a new measurement."
      reset_full
      view.invalidate
    end

    # ─── Create colored ribbon (thin face strip) for visibility ───

    def create_ribbon_artifact(cat, total_ft, total_inches)
      model = Sketchup.active_model
      model.start_operation('LF Measurement', true)

      # Ensure tag exists
      tag = model.layers[LF_TAG] || model.layers.add(LF_TAG)

      grp = model.active_entities.add_group
      grp.layer = tag
      grp.name = "TO_LF: #{cat} #{'%.1f' % total_ft} ft"

      # Create a semi-transparent material for the ribbon
      rgba = LF_COLORS[cat] || LF_DEFAULT_COLOR
      mat_name = "TO_LF_#{cat.gsub(/\s+/,'_')}"
      mat = model.materials[mat_name]
      unless mat
        mat = model.materials.add(mat_name)
        mat.color = Sketchup::Color.new(rgba[0], rgba[1], rgba[2])
        mat.alpha = (rgba[3] || 160) / 255.0
      end

      # For each segment chain, create ribbon faces
      @segments.each do |chain|
        next if chain.length < 2
        chain.each_cons(2) do |a, b|
          add_ribbon_segment(grp.entities, a, b, mat)
        end
      end

      # Also add plain edges as backup (visible in wireframe mode)
      @segments.each do |chain|
        next if chain.length < 2
        chain.each_cons(2) do |a, b|
          e = grp.entities.add_line(a, b)
          e.material = mat if e
        end
      end

      # Store measurement data
      grp.set_attribute('TakeoffMeasurement', 'type', 'LF')
      grp.set_attribute('TakeoffMeasurement', 'category', cat)
      grp.set_attribute('TakeoffMeasurement', 'total_inches', total_inches)
      grp.set_attribute('TakeoffMeasurement', 'total_ft', total_ft)
      grp.set_attribute('TakeoffMeasurement', 'cost_code', @last_cc || '')
      grp.set_attribute('TakeoffMeasurement', 'note', @last_note || '')
      grp.set_attribute('TakeoffMeasurement', 'segment_count', @segments.select{|c| c.length >= 2}.length)
      grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)

      TakeoffTool.entity_registry[grp.entityID] = grp

      model.commit_operation
      @last_grp_eid = grp.entityID
      grp
    end

    # Create a thin ribbon face between two points
    def add_ribbon_segment(entities, pt_a, pt_b, mat)
      # Direction vector along the segment
      dir = pt_b.vector_to(pt_a).reverse
      return if dir.length < 0.001

      # Find a perpendicular offset vector for ribbon width
      # Try crossing with Z axis first
      up = Geom::Vector3d.new(0, 0, 1)
      perp = dir.cross(up)

      # If segment is vertical, cross with X axis instead
      if perp.length < 0.001
        perp = dir.cross(Geom::Vector3d.new(1, 0, 0))
      end

      return if perp.length < 0.001
      perp.normalize!
      offset = perp.transform(Geom::Transformation.scaling(RIBBON_WIDTH / 2.0))

      # Four corners of the ribbon
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
        # If face creation fails (collinear points etc), just add an edge
        puts "Takeoff LF: ribbon face failed: #{e.message}"
      end
    end

    def add_to_results(cat, total_ft, total_inches)
      seg_count = @segments.select{|c| c.length >= 2}.length

      result = {
        entity_id: @last_grp_eid,
        tag: LF_TAG,
        definition_name: "Manual LF: #{cat}",
        display_name: "📏 #{cat} — #{'%.1f' % total_ft} LF#{seg_count > 1 ? " (#{seg_count} segs)" : ''}#{@last_note && !@last_note.empty? ? ' — ' + @last_note : ''}",
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
          element_type: 'Manual Measurement',
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

      # Refresh dashboard
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

      if mtype == 'SF'
        display = "📐 #{cat} — #{'%.1f' % total_sf} SF (#{face_count} face#{'s' if face_count>1})#{note && !note.empty? ? ' — ' + note : ''}"
        lf_val = 0.0
        sf_val = total_sf
      else
        display = "📏 #{cat} — #{'%.1f' % total_ft} LF#{seg_count > 1 ? " (#{seg_count} segs)" : ''}#{note && !note.empty? ? ' — ' + note : ''}"
        lf_val = total_ft
        sf_val = 0.0
      end

      result = {
        entity_id: grp.entityID,
        tag: LF_TAG,
        definition_name: "Manual #{mtype}: #{cat}",
        display_name: display,
        material: '',
        is_solid: false,
        instance_count: 1,
        volume_ft3: 0.0,
        volume_bf: 0.0,
        area_sf: sf_val,
        linear_ft: lf_val,
        bb_width_in: 0, bb_height_in: 0, bb_depth_in: 0,
        ifc_type: nil,
        warnings: [],
        parsed: {
          auto_category: cat,
          element_type: 'Manual Measurement',
          function: mtype,
          material: note,
          thickness: '',
          size_nominal: '',
          revit_id: nil
        },
        source: mtype == 'SF' ? :manual_sf : :manual_lf
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

  def self.activate_lf_tool
    Sketchup.active_model.select_tool(MeasureLFTool.new)
  end

  def self.activate_lf_tool_for_category(cat)
    Sketchup.active_model.select_tool(MeasureLFTool.new(cat))
  end
end
