module TakeoffTool
  class DashCategories
    def self.register_callbacks(dialog)

      dialog.add_action_callback('setCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          cat = data['val'].to_s
          puts "Takeoff: setCategory eid=#{eid} cat=#{cat}"
          _ca = TakeoffTool.category_assignments
          _sr = TakeoffTool.scan_results
          old_cat = _ca[eid] || _sr.find { |r| r[:entity_id] == eid }&.dig(:parsed, :auto_category) || 'Uncategorized'
          _ca[eid] = cat
          RecatLog.log_change(eid, cat)
          # Persist to model — clear subcategory on category change
          TakeoffTool.save_assignment(eid, 'category', cat)
          TakeoffTool.save_assignment(eid, 'subcategory', '')
          _sr.each { |r| if r[:entity_id] == eid; r[:parsed][:auto_subcategory] = ''; break; end }
          # Cascade to nested children (IFC arrays/groups contain child scan entities)
          nested = TakeoffTool.find_nested_scan_eids(eid)
          if nested.any?
            puts "  cascading '#{cat}' to #{nested.length} nested children"
            nested.each do |ceid|
              _ca[ceid] = cat
              TakeoffTool.save_assignment(ceid, 'category', cat)
              TakeoffTool.save_assignment(ceid, 'subcategory', '')
              _sr.each { |r| if r[:entity_id] == ceid; r[:parsed][:auto_subcategory] = ''; break; end }
            end
          end
          # IFC: cascade to all instances of the same definition (compound layers)
          # so the duplicate instance stays in sync
          if (IFCParser.ifc_model?(Sketchup.active_model) rescue false)
            match = _sr.find { |r| r[:entity_id] == eid }
            if match
              dname = match[:definition_name]
              _sr.each do |r|
                next if r[:entity_id] == eid
                next unless r[:definition_name] == dname
                ceid = r[:entity_id]
                next if _ca[ceid] == cat  # already correct
                _ca[ceid] = cat
                TakeoffTool.save_assignment(ceid, 'category', cat)
                TakeoffTool.save_assignment(ceid, 'subcategory', '')
                r[:parsed][:auto_subcategory] = ''
              end
            end
          end
          # Learning system: capture reclassification
          begin; LearningSystem.capture(eid, old_cat, cat); rescue => le; puts "Learning capture error: #{le.message}"; end
          Dashboard.send_live_data
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
          TakeoffTool.trigger_backup
        rescue => e
          puts "Takeoff setCategory error: #{e.message}\n  #{e.backtrace.first(3).join("\n  ")}"
        end
      end

      dialog.add_action_callback('addCustomCategory') do |_ctx, name_str|
        raw = name_str.to_s.strip
        next if raw.empty?
        container = nil
        if raw.start_with?('{')
          require 'json'
          data = JSON.parse(raw) rescue {}
          name = (data['name'] || '').strip
          container = (data['container'] || '').strip
          container = nil if container.empty?
        else
          name = raw
        end
        next if name.empty?
        TakeoffTool.add_custom_category(name, target_container: container)
        puts "Takeoff: addCustomCategory '#{name}' → container: #{container || 'auto'}"
      end

      # Bulk set category for multiple entities at once
      dialog.add_action_callback('bulkSetCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = data['eids'] || []
          cat = data['val'].to_s
          puts "Takeoff: bulkSetCategory #{eids.length} items -> #{cat}"
          _ca = TakeoffTool.category_assignments
          _sr = TakeoffTool.scan_results
          first_old_cat = nil
          all_eids = []
          eids.each do |eid|
            eid_i = eid.to_i
            all_eids << eid_i
            # Cascade to nested children
            nested = TakeoffTool.find_nested_scan_eids(eid_i)
            all_eids.concat(nested) if nested.any?
          end
          all_eids.uniq!
          puts "  (#{all_eids.length} total with nested children)" if all_eids.length > eids.length
          all_eids.each do |eid_i|
            old_cat = _ca[eid_i] || _sr.find { |r| r[:entity_id] == eid_i }&.dig(:parsed, :auto_category) || 'Uncategorized'
            first_old_cat ||= old_cat
            _ca[eid_i] = cat
            RecatLog.log_change(eid_i, cat)
            TakeoffTool.save_assignment(eid_i, 'category', cat)
            TakeoffTool.save_assignment(eid_i, 'subcategory', '')
            _sr.each { |r| if r[:entity_id] == eid_i; r[:parsed][:auto_subcategory] = ''; break; end }
          end
          # Learning system: capture from first entity in bulk
          if eids.length > 0 && first_old_cat
            begin; LearningSystem.capture(eids.first.to_i, first_old_cat, cat); rescue => le; puts "Learning capture error: #{le.message}"; end
          end
          Dashboard.send_live_data
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
          TakeoffTool.trigger_backup
        rescue => e
          puts "Takeoff bulkSetCategory error: #{e.message}"
        end
      end

      # Rename an entire category (delegates to atomic TakeoffTool.rename_category)
      dialog.add_action_callback('renameCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          old_name = data['oldName'].to_s.strip
          new_name = data['newName'].to_s.strip
          puts "Takeoff: renameCategory '#{old_name}' -> '#{new_name}'"
          TakeoffTool.rename_category(old_name, new_name)
        rescue => e
          puts "Takeoff renameCategory error: #{e.message}"
        end
      end

      dialog.add_action_callback('deleteCategory') do |_ctx, name_str|
        name = name_str.to_s.strip
        TakeoffTool.remove_category(name)
        puts "Takeoff: deleteCategory '#{name}'"
      end

      dialog.add_action_callback('addEmptyCategory') do |_ctx, name_str|
        name = name_str.to_s.strip
        unless name.empty?
          TakeoffTool.add_custom_category(name)
          Dashboard.send_live_data
          puts "Takeoff: addEmptyCategory '#{name}'"
        end
      end

    end
  end
end
