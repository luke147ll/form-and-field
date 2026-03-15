module TakeoffTool
  class DashMeasurement
    def self.register_callbacks(dialog)

      dialog.add_action_callback('activateLF') do |_ctx|
        TakeoffTool.activate_lf_tool
      end

      dialog.add_action_callback('activateLFForCat') do |_ctx, cat_str|
        TakeoffTool.activate_lf_tool_for_category(cat_str.to_s)
      end

      dialog.add_action_callback('activateSF') do |_ctx|
        TakeoffTool.activate_sf_tool
      end

      dialog.add_action_callback('activateSFForCat') do |_ctx, cat_str|
        TakeoffTool.activate_sf_tool_for_category(cat_str.to_s)
      end

      dialog.add_action_callback('startNormalSample') do |_ctx, cat_str|
        TakeoffTool.activate_normal_sample_tool(cat_str.to_s)
      end

      dialog.add_action_callback('activateBox') do |_ctx|
        TakeoffTool.activate_box_tool
      end

      dialog.add_action_callback('activateBoxForCat') do |_ctx, cat_str|
        TakeoffTool.activate_box_tool_for_category(cat_str.to_s)
      end

      dialog.add_action_callback('clearNormal') do |_ctx, cat_str|
        begin
          cat = cat_str.to_s
          m = Sketchup.active_model
          m.set_attribute('TakeoffSFNormals', cat, nil) if m
          puts "Takeoff: Cleared sampled normal for '#{cat}'"
          Scanner.recalculate_sf
          Dashboard.send_live_data
        rescue => e
          puts "Takeoff clearNormal error: #{e.message}"
        end
      end

      dialog.add_action_callback('recalculateSF') do |_ctx|
        begin
          count = Scanner.recalculate_sf
          Dashboard.send_live_data
          dialog.execute_script("console.log('Recalculated SF for #{count} entities')")
        rescue => e
          puts "Dashboard: recalculateSF error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('debugArea') do |_ctx, eid_str|
        begin
          eid = eid_str.to_i
          Scanner.debug_area(eid)
        rescue => e
          puts "[FF Debug] debugArea error: #{e.message}"
        end
      end

      dialog.add_action_callback('debugAreaCategory') do |_ctx, cat_str|
        begin
          Scanner.debug_area_category(cat_str.to_s)
        rescue => e
          puts "[FF Debug] debugAreaCategory error: #{e.message}"
        end
      end

      dialog.add_action_callback('debugOcclusion') do |_ctx, cat_str|
        begin
          Scanner.debug_occlusion(cat_str.to_s)
        rescue => e
          puts "[FF Debug] debugOcclusion error: #{e.message}"
        end
      end

      dialog.add_action_callback('debugOccSingle') do |_ctx, eid_str|
        begin
          Scanner.debug_occlusion_single(eid_str.to_i)
        rescue => e
          puts "[FF Debug] debugOccSingle error: #{e.message}"
        end
      end

      dialog.add_action_callback('clearDebug') do |_ctx|
        begin
          Scanner.clear_debug
        rescue => e
          puts "[FF Debug] clearDebug error: #{e.message}"
        end
      end

      # ─── Measurement visibility callbacks ───

      dialog.add_action_callback('toggleMeasurement') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          show = data['show']
          if show
            Highlighter.show_measurement_highlight(eid)
          else
            Highlighter.hide_measurement_highlight(eid)
          end
        rescue => e
          puts "Takeoff toggleMeasurement error: #{e.message}"
        end
      end

      dialog.add_action_callback('showAllMeasurements') do |_ctx|
        Highlighter.show_all_measurement_highlights
        Dashboard.send_measurement_data
      end

      dialog.add_action_callback('hideAllMeasurements') do |_ctx|
        Highlighter.hide_all_measurement_highlights
        Dashboard.send_measurement_data
      end

      dialog.add_action_callback('deleteMeasurement') do |_ctx, eid_str|
        begin
          eid = eid_str.to_s.to_i
          Highlighter.delete_measurement(eid)
          Dashboard.send_live_data
          Dashboard.send_measurement_data
        rescue => e
          puts "Takeoff deleteMeasurement error: #{e.message}"
        end
      end

      dialog.add_action_callback('requestMeasurements') do |_ctx|
        Dashboard.send_measurement_data
      end

      # ── Derived Parts ──

      dialog.add_action_callback('createDerivedPart') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          m = Sketchup.active_model
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          id = "dp_#{Time.now.to_i}_#{rand(1000)}"
          parts[id] = data
          m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
          Dashboard.send_measurement_data
        rescue => e
          puts "Dashboard createDerivedPart error: #{e.message}"
        end
      end

      dialog.add_action_callback('deleteDerivedPart') do |_ctx, id_str|
        begin
          require 'json'
          m = Sketchup.active_model
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          parts.delete(id_str.to_s)
          m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
          Dashboard.send_measurement_data
        rescue => e
          puts "Dashboard deleteDerivedPart error: #{e.message}"
        end
      end

      dialog.add_action_callback('editDerivedPart') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          m = Sketchup.active_model
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          id = data.delete('id')
          if parts[id]
            data.each { |k, v| parts[id][k] = v }
            m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
          end
          Dashboard.send_measurement_data
        rescue => e
          puts "Dashboard editDerivedPart error: #{e.message}"
        end
      end

      # ── Category Scan Measurement ──

      dialog.add_action_callback('generateCategoryMeasurement') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat  = data['category'].to_s
          unit = data['unit'].to_s       # LF, SF, CF, or BM (beam → treated as LF)
          unit = 'LF' if unit == 'BM'    # Beam inventory uses LF computation
          m = Sketchup.active_model

          sr = TakeoffTool.filtered_scan_results || []
          ca = TakeoffTool.category_assignments || {}
          reg = TakeoffTool.instance_variable_get(:@entity_registry) || {}
          total = 0.0
          count = 0
          eids  = []
          seen_eids = {}
          mv_active = TakeoffTool.active_mv_view != nil
          seen_defns = mv_active ? {} : nil
          is_ifc = (IFCParser.ifc_model?(m) rescue false)
          skipped_mv = 0
          skipped_ifc = 0

          # IFC two-pass: find preferred instance per definition
          # (prefer explicitly assigned instances so recategorized entities count correctly)
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

          puts ""
          puts "═══ generateCategoryMeasurement: '#{cat}' #{unit} ═══"
          puts "  scan_results total: #{sr.length}#{mv_active ? ' (multiverse dedup ON)' : ''}#{is_ifc ? ' (IFC dedup ON)' : ''}"

          sr.each do |r|
            next if r[:source] == :manual_lf || r[:source] == :manual_sf || r[:source] == :manual_box
            eid = r[:entity_id]
            assigned = ca[eid]
            auto = (r[:parsed][:auto_category] rescue nil)
            if assigned.nil?
              e = reg[eid]
              assigned = (e && e.valid?) ? (e.get_attribute('TakeoffAssignments', 'category') rescue nil) : nil
            end
            rcat = assigned || auto || 'Uncategorized'
            next unless rcat == cat

            val = case unit
                  when 'LF' then (r[:linear_ft] || 0).to_f
                  when 'SF' then (r[:area_sf] || 0).to_f
                  when 'CF' then (r[:volume_ft3] || 0).to_f
                  else 0.0
                  end
            next if val <= 0

            if seen_eids[eid]
              next
            end
            seen_eids[eid] = true

            # Multiverse dedup only when A/B is active
            if seen_defns
              e ||= reg[eid]
              defn_name = (e && e.valid? && e.respond_to?(:definition)) ? e.definition.name : (r[:definition_name] || r[:display_name])
              dedup_key = "#{defn_name}|#{val.round(2)}"
              if seen_defns[dedup_key]
                skipped_mv += 1
                next
              end
              seen_defns[dedup_key] = true
            end

            # IFC compound layer dedup: only count the preferred instance per definition
            if ifc_preferred
              dname = r[:definition_name] || r[:display_name] || ''
              pref = ifc_preferred[dname]
              if pref && pref[:eid] != eid
                skipped_ifc += 1
                next
              end
            end

            total += val
            count += 1
            eids << eid
            puts "  #{count}. eid=#{eid} '#{r[:display_name]}' = #{val.round(2)} #{unit}"
          end
          puts "  Skipped #{skipped_mv} multiverse duplicates" if skipped_mv > 0
          puts "  Skipped #{skipped_ifc} IFC compound duplicates" if skipped_ifc > 0
          puts "  TOTAL: #{total.round(2)} #{unit} from #{count} entities"
          puts "═══════════════════════════════════════════════"

          if total > 0
            dp_json = m.get_attribute('FormAndField', 'derived_parts')
            parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
            # Replace existing category_scan for same category+unit (prevent duplicates)
            existing = parts.find { |_k, v| v['sourceType'] == 'category_scan' && v['category'] == cat && v['unit'] == unit }
            id = existing ? existing[0] : "csm_#{Time.now.to_i}_#{rand(1000)}"
            parts[id] = {
              'name'          => "#{cat} (auto #{unit})",
              'category'      => cat,
              'sourceType'    => 'category_scan',
              'sourceUnit'    => unit,
              'unit'          => unit,
              'multiplier'    => 1.0,
              'computedValue' => total.round(2),
              'entityCount'   => count,
              'entityIds'     => eids,
              'note'          => "Scanned from #{count} entities"
            }
            m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
            Dashboard.send_measurement_data
          else
            dialog.execute_script("showToast('No #{unit} data found for #{cat.gsub("'","\\\\'")}','warning')")
          end
        rescue => e
          puts "Dashboard generateCategoryMeasurement error: #{e.message}"
        end
      end

      # ═══ OVERCOUNT FIX ═══

      dialog.add_action_callback('fixOvercount') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          category = data['category']
          sr = TakeoffTool.scan_results
          reg = TakeoffTool.entity_registry
          next unless sr && reg && category

          removed = 0
          sr.reject! do |r|
            next false unless r[:parsed][:auto_category] == category
            entity = reg[r[:entity_id]]
            next false unless entity && entity.valid?
            mt = r[:parsed][:measurement_type] || Parser.measurement_for(category)
            next false unless mt && mt.start_with?('ea')
            # Check if this entity is nested inside a parent in the same category
            p = entity.parent
            if p.is_a?(Sketchup::ComponentDefinition)
              cat_eids = sr.select { |r2| r2[:parsed][:auto_category] == category }.map { |r2| r2[:entity_id] }
              is_child = p.instances.any? { |pinst| pinst.valid? && cat_eids.include?(pinst.entityID) }
              if is_child
                removed += 1
                true
              else
                false
              end
            else
              false
            end
          end

          puts "[FF] fixOvercount: removed #{removed} children from #{category}"
          Dashboard.send_live_data
        rescue => e
          puts "fixOvercount error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

    end
  end
end
