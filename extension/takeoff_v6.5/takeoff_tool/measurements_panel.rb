module TakeoffTool
  module MeasurementsPanel
    @dialog = nil

    def self.visible?
      @dialog && @dialog.visible?
    end

    def self.show
      if @dialog && @dialog.visible?
        send_data
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Form and Field \u2014 Measurements",
        preferences_key: "TakeoffMeasPanel",
        width: 1000, height: 700, left: 120, top: 100,
        resizable: true, style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(File.join(PLUGIN_DIR, 'ui', 'measurements_panel.html'))

      register_callbacks
      @dialog.set_on_closed { @dialog = nil }
      @dialog.show
    end

    def self.send_data
      return unless @dialog && @dialog.visible?
      require 'json'
      m = Sketchup.active_model
      return unless m

      measurements = collect_measurements(m)
      scan_totals  = compute_scan_totals
      containers   = TakeoffTool.master_containers || []
      categories   = TakeoffTool.master_categories || []
      cost_codes   = build_cost_codes
      derived      = load_derived_parts

      payload = {
        measurements: measurements,
        scanTotals:   scan_totals,
        containers:   containers,
        categories:   categories,
        costCodes:    cost_codes,
        derivedParts: derived
      }

      js = JSON.generate(payload)
      esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
      @dialog.execute_script("receiveData('#{esc}')")
    rescue => e
      puts "[FF MeasPanel] send_data error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    end

    # ─── Derived Parts persistence ───

    def self.load_derived_parts
      require 'json'
      m = Sketchup.active_model
      return {} unless m
      json = m.get_attribute('FormAndField', 'derived_parts')
      return {} unless json && !json.empty?
      JSON.parse(json) rescue {}
    end

    def self.save_derived_parts(parts)
      require 'json'
      m = Sketchup.active_model
      return unless m
      m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
    end

    def self.compute_derived_value(part)
      source_val = resolve_source_value(part)
      return 0.0 unless source_val
      mult = (part['multiplier'] || 1.0).to_f
      (source_val * mult).round(2)
    end

    def self.resolve_source_value(part)
      case part['sourceType']
      when 'category_total'
        totals = compute_scan_totals
        cat_data = totals[part['sourceCategory']]
        return nil unless cat_data
        unit = (part['sourceUnit'] || 'SF').upcase
        case unit
        when 'LF' then cat_data[:lf]
        when 'SF' then cat_data[:sf]
        when 'CF', 'VOL' then cat_data[:vol]
        else cat_data[:count]
        end
      when 'measurement'
        eid = (part['sourceEid'] || 0).to_i
        m = Sketchup.active_model
        return nil unless m
        grp = m.entities.grep(Sketchup::Group).find { |g| g.valid? && g.entityID == eid }
        return nil unless grp
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        case mtype
        when 'LF' then grp.get_attribute('TakeoffMeasurement', 'total_ft')
        when 'SF' then grp.get_attribute('TakeoffMeasurement', 'total_sf')
        when 'BOX' then grp.get_attribute('TakeoffMeasurement', 'volume_cf')
        else 0
        end
      when 'manual'
        (part['manualValue'] || 0).to_f
      else
        0
      end
    end

    # ─── Data collection ───

    def self.collect_measurements(model)
      measurements = []
      model.entities.grep(Sketchup::Group).each do |grp|
        next unless grp.valid?
        mtype = grp.get_attribute('TakeoffMeasurement', 'type')
        next unless mtype
        next if mtype == 'BENCHMARK'
        next if mtype == 'GRID'  # Gridlines are managed in CAD overlay tab, not measurements

        cat   = grp.get_attribute('TakeoffMeasurement', 'category') || 'Custom'
        vis   = grp.get_attribute('TakeoffMeasurement', 'highlights_visible')
        vis   = false if vis.nil?
        note  = grp.get_attribute('TakeoffMeasurement', 'note') || ''
        rgba  = grp.get_attribute('TakeoffMeasurement', 'color_rgba')
        color = begin; JSON.parse(rgba); rescue; nil; end
        pname = grp.get_attribute('TakeoffMeasurement', 'part_name') || ''
        cc    = grp.get_attribute('TakeoffMeasurement', 'cost_code') || ''

        entry = {
          eid: grp.entityID, type: mtype, category: cat, visible: vis,
          note: note, color: color, partName: pname, costCode: cc
        }

        case mtype
        when 'SF'
          entry[:value] = grp.get_attribute('TakeoffMeasurement', 'total_sf') || 0
          entry[:unit]  = 'SF'
          entry[:faceCount] = grp.get_attribute('TakeoffMeasurement', 'face_count') || 0
        when 'ELEV'
          entry[:value] = grp.get_attribute('TakeoffMeasurement', 'elevation') || 0
          entry[:unit]  = grp.get_attribute('TakeoffMeasurement', 'benchmark_unit') || 'feet'
          entry[:label] = grp.get_attribute('TakeoffMeasurement', 'elevation_label') || ''
          entry[:custom_label] = grp.get_attribute('TakeoffMeasurement', 'custom_label') || ''
        when 'NOTE'
          entry[:value] = 0
          entry[:unit]  = ''
          entry[:label_type] = grp.get_attribute('TakeoffMeasurement', 'label_type') || ''
        when 'BOX'
          entry[:value] = grp.get_attribute('TakeoffMeasurement', 'volume_cf') || 0
          entry[:unit]  = 'CF'
          entry[:width_in]    = grp.get_attribute('TakeoffMeasurement', 'width_in') || 0
          entry[:depth_in]    = grp.get_attribute('TakeoffMeasurement', 'depth_in') || 0
          entry[:height_in]   = grp.get_attribute('TakeoffMeasurement', 'height_in') || 0
          entry[:total_sf]    = grp.get_attribute('TakeoffMeasurement', 'total_sf') || 0
          entry[:net_wall_sf] = grp.get_attribute('TakeoffMeasurement', 'net_wall_sf') || 0
        else # LF
          entry[:value]    = grp.get_attribute('TakeoffMeasurement', 'total_ft') || 0
          entry[:unit]     = 'LF'
          entry[:segments] = grp.get_attribute('TakeoffMeasurement', 'segment_count') || 1
        end

        measurements << entry
      end
      measurements
    end

    def self.compute_scan_totals
      totals = {}
      sr = TakeoffTool.filtered_scan_results || []
      ca = TakeoffTool.category_assignments || {}
      reg = TakeoffTool.instance_variable_get(:@entity_registry) || {}
      seen = {}
      m = Sketchup.active_model
      is_ifc = (IFCParser.ifc_model?(m) rescue false)

      # IFC two-pass: find preferred instance per definition
      ifc_preferred = nil
      if is_ifc
        ifc_preferred = {}
        sr.each do |r|
          next if r[:source] == :manual_lf || r[:source] == :manual_sf || r[:source] == :manual_box
          dname = r[:definition_name] || r[:display_name] || ''
          next if dname.empty?
          eid2 = r[:entity_id]
          has_ca = !!ca[eid2]
          if !has_ca
            e2 = reg[eid2]
            has_ca = !!(e2 && e2.valid? && (e2.get_attribute('TakeoffAssignments', 'category') rescue nil))
          end
          prev = ifc_preferred[dname]
          if prev.nil? || (has_ca && !prev[:assigned])
            ifc_preferred[dname] = { eid: eid2, assigned: has_ca }
          end
        end
      end

      sr.each do |r|
        next if r[:source] == :manual_lf || r[:source] == :manual_sf || r[:source] == :manual_box
        eid = r[:entity_id]
        next if seen[eid]
        seen[eid] = true
        assigned = ca[eid]
        if assigned.nil?
          e = reg[eid]
          assigned = (e && e.valid?) ? (e.get_attribute('TakeoffAssignments', 'category') rescue nil) : nil
        end
        cat = assigned || (r[:parsed][:auto_category] rescue nil) || 'Uncategorized'
        # IFC compound layer dedup: only count preferred instance per definition
        if ifc_preferred
          dname = r[:definition_name] || r[:display_name] || ''
          pref = ifc_preferred[dname]
          next if pref && pref[:eid] != eid
        end
        totals[cat] ||= { lf: 0.0, sf: 0.0, vol: 0.0, count: 0 }
        totals[cat][:count] += 1
        totals[cat][:lf]  += (r[:linear_ft] || 0).to_f
        totals[cat][:sf]  += (r[:area_sf] || 0).to_f
        totals[cat][:vol] += (r[:volume_ft3] || 0).to_f
      end
      totals
    end

    def self.build_cost_codes
      require 'json'
      p = File.join(PLUGIN_DIR, 'config', 'cost_codes.json')
      return [] unless File.exist?(p)
      d = JSON.parse(File.read(p))
      d['codes'] || []
    rescue
      []
    end

    # ─── Callbacks ───

    def self.register_callbacks
      @dialog.add_action_callback('requestData') do |_ctx|
        begin
          send_data
        rescue => e
          puts "[FF MeasPanel] requestData error: #{e.message}"
        end
      end

      @dialog.add_action_callback('toggleMeasurement') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid  = data['eid'].to_i
          show = data['show']
          if show
            Highlighter.show_measurement_highlight(eid)
          else
            Highlighter.hide_measurement_highlight(eid)
          end
        rescue => e
          puts "[FF MeasPanel] toggleMeasurement error: #{e.message}"
        end
      end

      @dialog.add_action_callback('showAllMeasurements') do |_ctx|
        Highlighter.show_all_measurement_highlights
        send_data
        Dashboard.invalidate_measurement_cache if Dashboard.respond_to?(:invalidate_measurement_cache)
        Dashboard.send_measurement_data if Dashboard.respond_to?(:send_measurement_data)
      end

      @dialog.add_action_callback('hideAllMeasurements') do |_ctx|
        Highlighter.hide_all_measurement_highlights
        send_data
        Dashboard.invalidate_measurement_cache if Dashboard.respond_to?(:invalidate_measurement_cache)
        Dashboard.send_measurement_data if Dashboard.respond_to?(:send_measurement_data)
      end

      @dialog.add_action_callback('deleteMeasurement') do |_ctx, eid_str|
        begin
          eid = eid_str.to_s.to_i
          Highlighter.delete_measurement(eid)
          send_data
          Dashboard.send_live_data if Dashboard.respond_to?(:send_live_data)
        rescue => e
          puts "[FF MeasPanel] deleteMeasurement error: #{e.message}"
        end
      end

      @dialog.add_action_callback('zoomToMeasurement') do |_ctx, eid_str|
        begin
          eid = eid_str.to_s.to_i
          m = Sketchup.active_model
          grp = m.entities.grep(Sketchup::Group).find { |g| g.valid? && g.entityID == eid }
          if grp
            m.selection.clear
            m.selection.add(grp)
            m.active_view.zoom(m.selection)
          end
        rescue => e
          puts "[FF MeasPanel] zoomToMeasurement error: #{e.message}"
        end
      end

      @dialog.add_action_callback('activateLF') do |_ctx|
        TakeoffTool.activate_lf_tool
      end

      @dialog.add_action_callback('activateSF') do |_ctx|
        TakeoffTool.activate_sf_tool
      end

      @dialog.add_action_callback('activateBox') do |_ctx|
        TakeoffTool.activate_box_tool
      end

      @dialog.add_action_callback('activateLFForCat') do |_ctx, cat_str|
        TakeoffTool.activate_lf_tool_for_category(cat_str.to_s)
      end

      @dialog.add_action_callback('activateSFForCat') do |_ctx, cat_str|
        TakeoffTool.activate_sf_tool_for_category(cat_str.to_s)
      end

      @dialog.add_action_callback('activateBoxForCat') do |_ctx, cat_str|
        TakeoffTool.activate_box_tool rescue nil
      end

      @dialog.add_action_callback('editMeasNote') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid  = data['eid'].to_i
          note = data['note'].to_s
          m = Sketchup.active_model
          grp = m.entities.grep(Sketchup::Group).find { |g| g.valid? && g.entityID == eid }
          grp.set_attribute('TakeoffMeasurement', 'note', note) if grp
        rescue => e
          puts "[FF MeasPanel] editMeasNote error: #{e.message}"
        end
      end

      @dialog.add_action_callback('recalcMeasurements') do |_ctx|
        send_data
      end

      # ─── Derived Parts callbacks ───

      @dialog.add_action_callback('createDerivedPart') do |_ctx, json_str|
        begin
          require 'json'
          data  = JSON.parse(json_str.to_s)
          parts = load_derived_parts
          id    = "dp_#{Time.now.to_i}_#{rand(1000)}"
          part  = {
            'name'           => data['name'] || 'New Part',
            'category'       => data['category'] || '',
            'sourceType'     => data['sourceType'] || 'category_total',
            'sourceCategory' => data['sourceCategory'] || '',
            'sourceEid'      => data['sourceEid'] || 0,
            'sourceUnit'     => data['sourceUnit'] || 'SF',
            'multiplier'     => (data['multiplier'] || 1.0).to_f,
            'unit'           => data['unit'] || 'SF',
            'note'           => data['note'] || '',
            'costCode'       => data['costCode'] || '',
            'manualValue'    => (data['manualValue'] || 0).to_f
          }
          part['computedValue'] = compute_derived_value(part)
          parts[id] = part
          save_derived_parts(parts)
          send_data
        rescue => e
          puts "[FF MeasPanel] createDerivedPart error: #{e.message}"
        end
      end

      @dialog.add_action_callback('editDerivedPart') do |_ctx, json_str|
        begin
          require 'json'
          data  = JSON.parse(json_str.to_s)
          parts = load_derived_parts
          id    = data['id']
          if parts[id]
            data.each { |k, v| parts[id][k] = v unless k == 'id' }
            parts[id]['computedValue'] = compute_derived_value(parts[id])
            save_derived_parts(parts)
          end
          send_data
        rescue => e
          puts "[FF MeasPanel] editDerivedPart error: #{e.message}"
        end
      end

      @dialog.add_action_callback('deleteDerivedPart') do |_ctx, id_str|
        begin
          parts = load_derived_parts
          parts.delete(id_str.to_s)
          save_derived_parts(parts)
          send_data
        rescue => e
          puts "[FF MeasPanel] deleteDerivedPart error: #{e.message}"
        end
      end
    end
  end
end
