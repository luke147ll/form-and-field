module TakeoffTool
  class DashColor
    def self.register_callbacks(dialog)

      dialog.add_action_callback('setCosmetic') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = data['eids'] || []
          val = data['val'] == true
          eids.each do |eid|
            e = TakeoffTool.find_entity(eid.to_i)
            next unless e && e.valid?
            if val
              e.set_attribute('FormAndField', 'cosmetic', true)
            else
              e.delete_attribute('FormAndField', 'cosmetic')
            end
          end
          puts "[FF] setCosmetic #{eids.length} items -> #{val}"
          Dashboard.send_live_data
        rescue => e
          puts "setCosmetic error: #{e.message}"
        end
      end

      dialog.add_action_callback('setCustomColor') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          type = data['type'].to_s
          key = data['key'].to_s
          color = data['color'].to_s
          opacity = data['opacity'] ? data['opacity'].to_f : nil
          plural = {'category'=>'categories','subcategory'=>'subcategories','assembly'=>'assemblies','entity'=>'entities','measurement'=>'measurements','container'=>'containers'}
          section = plural[type] || (type + 's')
          ColorController.set_color(section, key, color, opacity)
          # Also update legacy custom_colors for backward compat
          colors = Dashboard.load_custom_colors_for_view
          colors[section] ||= {}
          colors[section][key] = color
          Dashboard.save_custom_colors_for_view(colors)
          Highlighter.refresh_highlights
          # Do NOT call send_live_data here — it triggers receiveData → syncIsolation
          # which can queue hideEntities callbacks that override enforce_isolation.
          # JS already has updated CCOL and calls renderGroups() after this callback.
        rescue => e
          puts "Takeoff setCustomColor error: #{e.message}"
        end
      end

      dialog.add_action_callback('clearCustomColor') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          type = data['type'].to_s
          key = data['key'].to_s
          plural = {'category'=>'categories','subcategory'=>'subcategories','assembly'=>'assemblies','entity'=>'entities','measurement'=>'measurements','container'=>'containers'}
          section = plural[type] || (type + 's')
          ColorController.clear_color(section, key)
          # Also update legacy custom_colors for backward compat
          colors = Dashboard.load_custom_colors_for_view
          if colors[section]
            colors[section].delete(key)
          end
          Dashboard.save_custom_colors_for_view(colors)
          Highlighter.refresh_highlights
          # Do NOT call send_live_data here — same reason as setCustomColor.
        rescue => e
          puts "Takeoff clearCustomColor error: #{e.message}"
        end
      end

      dialog.add_action_callback('setCustomOpacity') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          type = data['type'].to_s
          key = data['key'].to_s
          opacity = data['opacity'].to_f
          plural = {'category'=>'categories','subcategory'=>'subcategories','assembly'=>'assemblies','entity'=>'entities','measurement'=>'measurements','container'=>'containers'}
          section = plural[type] || (type + 's')
          ColorController.set_opacity(section, key, opacity)
        rescue => e
          puts "Takeoff setCustomOpacity error: #{e.message}"
        end
      end

    end
  end
end
