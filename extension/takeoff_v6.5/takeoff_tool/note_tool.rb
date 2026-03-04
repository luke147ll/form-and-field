module TakeoffTool
  unless defined?(NOTE_TAG_LAYER)
  NOTE_TAG_LAYER = 'FF_Note_Tags'
  NOTE_DEFAULT_COLOR = [137, 180, 250]  # #89b4fa Catppuccin blue
  NOTE_TEXT_COLOR = [205, 214, 244]     # #cdd6f4 Catppuccin text
  NOTE_TEXT_HEIGHT = 1.5                # inches
  NOTE_PAD_X = 1.2
  NOTE_PAD_Z = 0.5
  NOTE_POINTER_HEIGHT = 0.4
  NOTE_STANDOFF = 0.1
  end # unless defined?(NOTE_TAG_LAYER)

  # ═══════════════════════════════════════════════════════════════
  # NOTE TOOL — Click to place text annotation labels in the model
  # ═══════════════════════════════════════════════════════════════
  class NoteTool
    def initialize
      @ip = Sketchup::InputPoint.new
      @hover_point = nil
      @notes_placed = 0
      @dialog_open = false
    end

    def activate
      @hover_point = nil
      @notes_placed = 0
      @dialog_open = false
      update_status
    end

    def deactivate(view)
      @note_dlg.close if @note_dlg rescue nil
      view.invalidate
    end

    def resume(view)
      update_status
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      return if @dialog_open
      @ip.pick(view, x, y)
      if @ip.valid?
        @hover_point = @ip.position
        # Show native inference tooltip (Endpoint, Midpoint, On Edge, etc.)
        view.tooltip = @ip.tooltip
      end
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return if @dialog_open
      @ip.pick(view, x, y)
      return unless @ip.valid?
      @click_point = @ip.position.clone
      show_note_dialog(view)
    end

    def onKeyDown(key, repeat, flags, view)
      if key == VK_ESCAPE
        Sketchup.active_model.select_tool(nil)
      end
    end

    def draw(view)
      return if @dialog_open
      @ip.draw(view) if @ip.valid?
      return unless @hover_point

      # "NOTE" label near cursor
      screen = view.screen_coords(@hover_point)
      txt_pt = Geom::Point3d.new(screen.x + 14, screen.y - 14, 0)
      view.draw_text(txt_pt, "NOTE", color: Sketchup::Color.new(*NOTE_DEFAULT_COLOR))
    end

    def getExtents
      Geom::BoundingBox.new
    end

    private

    def update_status
      placed = @notes_placed > 0 ? " (#{@notes_placed} placed)" : ""
      Sketchup.status_text = "Note Tool#{placed}: Click to place a note. ESC to exit."
    end

    def show_note_dialog(view)
      color_palette = [
        '#cba6f7','#89b4fa','#94e2d5','#a6e3a1','#fab387','#f38ba8',
        '#f9e2af','#f5c2e7','#89dceb','#b4befe','#f2cdcd','#74c7ec'
      ]
      color_circles = color_palette.map { |c|
        sel = c == '#89b4fa' ? 'border:2px solid #cdd6f4;' : 'border:2px solid transparent;'
        "<span class='cc' style='background:#{c};#{sel}' onclick=\"pickClr(this,'#{c}')\"></span>"
      }.join('')

      html = <<~HTML
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <style>#{PICK_DIALOG_CSS}
        body{overflow-y:auto}
        textarea{width:100%;min-height:60px;resize:vertical;background:#313244;color:#cdd6f4;border:1px solid #45475a;border-radius:4px;padding:6px 8px;font-family:Arial,sans-serif;font-size:12px;outline:none}
        textarea:focus{border-color:#89b4fa}
        select{width:100%;background:#313244;color:#cdd6f4;border:1px solid #45475a;border-radius:4px;padding:5px 8px;font-size:12px;outline:none;cursor:pointer}
        select:focus{border-color:#89b4fa}
        .clrs{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
        .cc{width:22px;height:22px;border-radius:50%;cursor:pointer;transition:transform .15s}
        .cc:hover{transform:scale(1.2)}
        .cc.picked{border:2px solid #cdd6f4 !important}
        </style></head><body>
        <h1>Place Note</h1>
        <label>Note Text</label>
        <textarea id="text" rows="3" placeholder="Enter note text..."></textarea>
        <label style="margin-top:10px;display:block">Label Type</label>
        <select id="labelType">
          <option value="None">None</option>
          <option value="Note" selected>Note</option>
          <option value="Info">Info</option>
          <option value="Warning">Warning</option>
          <option value="Action">Action</option>
          <option value="Question">Question</option>
        </select>
        <label style="margin-top:10px;display:block">Color</label>
        <div class="clrs">#{color_circles}</div>
        <div class="buttons">
          <button class="btn btn-cancel" onclick="sketchup.cancel()">Cancel</button>
          <button class="btn btn-ok" onclick="doOk()">OK</button>
        </div>
        <script>
        var selColor='#89b4fa';
        function pickClr(el,c){
          selColor=c;
          var all=document.querySelectorAll('.cc');
          for(var i=0;i<all.length;i++) all[i].classList.remove('picked');
          el.classList.add('picked');
        }
        function doOk(){
          var t=document.getElementById('text').value.trim();
          if(!t){document.getElementById('text').focus();return;}
          sketchup.ok(JSON.stringify({
            text:t,
            labelType:document.getElementById('labelType').value,
            color:selColor
          }));
        }
        document.addEventListener('keydown',function(e){
          if(e.key==='Escape')sketchup.cancel();
        });
        document.getElementById('text').focus();
        </script>
        </body></html>
      HTML

      @note_dlg.close if @note_dlg rescue nil
      @note_dlg = UI::HtmlDialog.new(
        dialog_title: "Place Note",
        preferences_key: "FFNoteTag",
        width: 340, height: 400,
        left: 200, top: 200,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      click_pt = @click_point.clone

      @note_dlg.add_action_callback('ok') do |_ctx, json_str|
        @note_dlg.close rescue nil
        @dialog_open = false
        require 'json'
        data = JSON.parse(json_str.to_s)
        text = data['text'].to_s.strip
        label_type = data['labelType'].to_s
        color_hex = data['color'].to_s
        unless text.empty?
          TakeoffTool.create_note_label(click_pt, text, label_type, color_hex, view)
          @notes_placed += 1
          update_status
        end
        view.invalidate
      end

      @note_dlg.add_action_callback('cancel') do |_ctx|
        @note_dlg.close rescue nil
        @dialog_open = false
        update_status
        view.invalidate
      end

      @dialog_open = true
      @note_dlg.set_html(html)
      @note_dlg.show
    end
  end

  # ═══════════════════════════════════════════════════════════════
  # CREATE NOTE LABEL — Build 3D callout label at a point
  # ═══════════════════════════════════════════════════════════════
  def self.create_note_label(point, text, label_type, color_hex, view)
    model = Sketchup.active_model
    model.start_operation('Place Note', true)

    # Parse hex color to RGB
    hex = color_hex.to_s.gsub('#', '')
    r = hex[0..1].to_i(16)
    g = hex[2..3].to_i(16)
    b = hex[4..5].to_i(16)
    rgb_color = [r, g, b]

    tag_layer = model.layers[NOTE_TAG_LAYER] || model.layers.add(NOTE_TAG_LAYER)
    grp = model.active_entities.add_group
    grp.layer = tag_layer

    # Build display text with optional prefix
    prefix = (label_type && label_type != 'None') ? "#{label_type.upcase}: " : ''
    display_text = prefix + text.gsub("\n", ' ')
    # Truncate for 3D label if very long
    display_3d = display_text.length > 60 ? display_text[0..56] + '...' : display_text
    grp.name = "FF_NOTE: #{display_3d}"
    ents = grp.entities

    # Reuse build_rect_label from elevation_tool
    build_rect_label(ents, model, display_3d, rgb_color, false, '')

    # Orient label facing camera (snapped to nearest 90 degrees)
    cam_angle = view ? camera_snap_angle(view) : 0.0
    s_rad = cam_angle * Math::PI / 180.0
    cs = Math.cos(s_rad)
    sn = Math.sin(s_rad)
    orient = Geom::Transformation.new([
      cs, -sn, 0, 0,
       0,   0, 1, 0,
      -sn, -cs, 0, 0,
       0,   0, 0, 1
    ])
    ents.transform_entities(orient, ents.to_a)

    # Position at click point with standoff
    tag_bb = Geom::BoundingBox.new
    ents.each { |e| tag_bb.add(e.bounds) }
    cx = (tag_bb.min.x + tag_bb.max.x) / 2.0
    cy = (tag_bb.min.y + tag_bb.max.y) / 2.0
    cz = tag_bb.min.z

    offset = Geom::Vector3d.new(
      point.x - cx,
      point.y - cy,
      point.z + NOTE_STANDOFF - cz
    )
    grp.transform!(Geom::Transformation.new(offset))

    # Set TakeoffMeasurement attributes
    require 'json'
    grp.set_attribute('TakeoffMeasurement', 'type', 'NOTE')
    grp.set_attribute('TakeoffMeasurement', 'category', 'Note Tags')
    grp.set_attribute('TakeoffMeasurement', 'note', text)
    grp.set_attribute('TakeoffMeasurement', 'label_type', label_type.to_s)
    grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate(rgb_color + [230]))
    grp.set_attribute('TakeoffMeasurement', 'point', JSON.generate([point.x, point.y, point.z]))
    grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.strftime('%Y-%m-%d %H:%M'))
    grp.set_attribute('TakeoffMeasurement', 'author', ENV['USERNAME'] || ENV['USER'] || 'Unknown')
    grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)

    TakeoffTool.entity_registry[grp.entityID] = grp
    model.commit_operation

    Dashboard.send_measurement_data rescue nil

    puts "Takeoff Note: '#{display_3d}' at [#{point.x.round(1)}, #{point.y.round(1)}, #{point.z.round(1)}]"
    grp
  end

  def self.activate_note_tool
    Sketchup.active_model.select_tool(NoteTool.new)
  end
end
