module TakeoffTool
  class DashEdits
    def self.register_callbacks(dialog)

      dialog.add_action_callback('setCostCode') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          code = data['val'].to_s
          puts "Takeoff: setCostCode eid=#{eid} code=#{code}"
          TakeoffTool.cost_code_assignments[eid] = code
          # Persist to model
          TakeoffTool.save_assignment(eid, 'cost_code', code)
        rescue => e
          puts "Takeoff setCostCode error: #{e.message}"
        end
      end

      dialog.add_action_callback('setSize') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          val = data['val'].to_s
          puts "Takeoff: setSize eid=#{eid} size=#{val}"
          # Save to entity attribute
          TakeoffTool.save_assignment(eid, 'size', val)
          # Update scan results
          TakeoffTool.scan_results.each do |r|
            if r[:entity_id] == eid
              r[:parsed][:size_nominal] = val
              break
            end
          end
        rescue => e
          puts "Takeoff setSize error: #{e.message}"
        end
      end

      # Set measurement type for a category (saves to model-level attribute)
      dialog.add_action_callback('setMeasurementType') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s
          mt = data['mt'].to_s
          puts "Takeoff: setMeasurementType cat=#{cat} mt=#{mt}"
          # Save to model-level attribute dictionary
          m = Sketchup.active_model
          if m
            m.set_attribute('TakeoffMeasurementTypes', cat, mt)
          end
          # Update all entities in this category in scan results
          _ca = TakeoffTool.category_assignments
          TakeoffTool.scan_results.each do |r|
            ecat = _ca[r[:entity_id]] || r[:parsed][:auto_category] || 'Uncategorized'
            if ecat == cat
              r[:parsed][:measurement_type] = mt
            end
          end
          # Recalculate SF areas for entities that may not have been computed during scan
          Scanner.recalculate_sf if %w[sf sf_cy sf_sheets].include?(mt)
          # Resend data so dashboard shows updated measurement types
          Dashboard.send_live_data
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "Takeoff setMeasurementType error: #{e.message}"
        end
      end

      dialog.add_action_callback('setSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          val = data['val'].to_s
          puts "Takeoff: setSubcategory eid=#{eid} sub=#{val}"
          TakeoffTool.save_assignment(eid, 'subcategory', val)
        rescue => e
          puts "Takeoff setSubcategory error: #{e.message}"
        end
      end

      dialog.add_action_callback('bulkSetSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = data['eids'] || []
          val = data['val'].to_s
          puts "Takeoff: bulkSetSubcategory #{eids.length} items -> #{val}"
          eids.each do |eid|
            TakeoffTool.save_assignment(eid.to_i, 'subcategory', val)
          end
          Dashboard.send_live_data
        rescue => e
          puts "Takeoff bulkSetSubcategory error: #{e.message}"
        end
      end

      # Bulk set size for multiple entities at once
      dialog.add_action_callback('bulkSetSize') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = data['eids'] || []
          val = data['val'].to_s
          puts "Takeoff: bulkSetSize #{eids.length} items -> #{val}"
          eids.each do |eid|
            eid_i = eid.to_i
            TakeoffTool.save_assignment(eid_i, 'size', val)
            TakeoffTool.scan_results.each do |r|
              if r[:entity_id] == eid_i
                r[:parsed][:size_nominal] = val
                break
              end
            end
          end
          Dashboard.send_live_data
        rescue => e
          puts "Takeoff bulkSetSize error: #{e.message}"
        end
      end

      # Bulk set cost code for multiple entities at once
      dialog.add_action_callback('bulkSetCostCode') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eids = data['eids'] || []
          code = data['val'].to_s
          puts "Takeoff: bulkSetCostCode #{eids.length} items -> #{code}"
          eids.each do |eid|
            eid_i = eid.to_i
            TakeoffTool.cost_code_assignments[eid_i] = code
            TakeoffTool.save_assignment(eid_i, 'cost_code', code)
          end
          Dashboard.send_live_data
        rescue => e
          puts "Takeoff bulkSetCostCode error: #{e.message}"
        end
      end

      # ── Cost code management callbacks ──

      dialog.add_action_callback('addCostCode') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.add_cost_code(data['code'].to_s.strip, data['description'].to_s.strip)
          Dashboard.send_live_data
        rescue => e
          puts "Takeoff addCostCode error: #{e.message}"
        end
      end

      dialog.add_action_callback('removeCostCode') do |_ctx, code_str|
        begin
          TakeoffTool.remove_cost_code(code_str.to_s.strip)
          Dashboard.send_live_data
        rescue => e
          puts "Takeoff removeCostCode error: #{e.message}"
        end
      end

      dialog.add_action_callback('importCostCodesCSV') do |_ctx|
        begin
          path = UI.openpanel('Import Cost Codes CSV', '', 'CSV Files|*.csv||')
          if path
            count = TakeoffTool.import_cost_codes_from_csv(path)
            Dashboard.send_live_data
            safe_count = count.to_i
            Dashboard.dialog.execute_script("if(typeof showToast==='function')showToast('Imported #{safe_count} cost codes','success')") rescue nil
          end
        rescue => e
          puts "Takeoff importCostCodesCSV error: #{e.message}"
        end
      end

      dialog.add_action_callback('setCategoryCostCode') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.set_category_cost_code(data['category'].to_s, data['code'].to_s)
          Dashboard.send_live_data
        rescue => e
          puts "Takeoff setCategoryCostCode error: #{e.message}"
        end
      end

    end
  end
end
