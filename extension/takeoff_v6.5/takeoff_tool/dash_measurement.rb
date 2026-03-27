module TakeoffTool
  class DashMeasurement
    def self.register_callbacks(dialog)

      dialog.add_action_callback('activateLF') do |_ctx|
        TakeoffTool.activate_lf_tool
      end

      dialog.add_action_callback('activateLFForCat') do |_ctx, cat_str|
        TakeoffTool.activate_lf_tool_for_category(cat_str.to_s)
      end

      dialog.add_action_callback('activateLFFace') do |_ctx|
        TakeoffTool.activate_lf_face_tool_for_category('Custom')
      end

      dialog.add_action_callback('activateSF') do |_ctx|
        TakeoffTool.activate_sf_tool
      end

      dialog.add_action_callback('polySF') do |_ctx|
        TakeoffTool.activate_poly_sf_tool
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

      dialog.add_action_callback('activateVol') do |_ctx|
        TakeoffTool.activate_vol_tool
      end

      dialog.add_action_callback('activateVolForCat') do |_ctx, cat_str|
        TakeoffTool.activate_vol_tool_for_category(cat_str.to_s)
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

      # ─── Create empty measurement card (container for parts) ───

      dialog.add_action_callback('createEmptyCard') do |_ctx, label_str|
        begin
          label = label_str.to_s.strip
          label = 'Untitled' if label.empty?
          m = Sketchup.active_model
          next unless m
          m.start_operation('Create Measurement Card', true)
          tag = m.layers['TO_Measurements'] || m.layers.add('TO_Measurements')
          grp = m.active_entities.add_group
          grp.entities.add_cpoint(ORIGIN)  # placeholder so SketchUp doesn't auto-delete empty group
          grp.layer = tag
          grp.name = "TO_CARD: #{label}"
          grp.set_attribute('TakeoffMeasurement', 'type', 'CARD')
          grp.set_attribute('TakeoffMeasurement', 'label', label)
          grp.set_attribute('TakeoffMeasurement', 'category', 'Custom')
          grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
          grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
          m.commit_operation
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "createEmptyCard error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateCardLabel') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          label = data['label'].to_s.strip
          grp = TakeoffTool.find_entity(eid)
          if grp && grp.valid? && grp.get_attribute('TakeoffMeasurement', 'type') == 'CARD'
            m = Sketchup.active_model
            m.start_operation('Rename Card', true)
            grp.set_attribute('TakeoffMeasurement', 'label', label)
            grp.name = "TO_CARD: #{label}"
            m.commit_operation
            Dashboard.invalidate_measurement_cache
            Dashboard.send_measurement_data
          end
        rescue => e
          puts "updateCardLabel error: #{e.message}"
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
          Dashboard.send_overlay_vis_state
        rescue => e
          puts "Takeoff toggleMeasurement error: #{e.message}"
        end
      end

      dialog.add_action_callback('showAllMeasurements') do |_ctx|
        Highlighter.show_all_measurement_highlights
        Dashboard.invalidate_measurement_cache
        Dashboard.send_measurement_data
        Dashboard.send_overlay_vis_state
      end

      dialog.add_action_callback('hideAllMeasurements') do |_ctx|
        Highlighter.hide_all_measurement_highlights
        Dashboard.invalidate_measurement_cache
        Dashboard.send_measurement_data
        Dashboard.send_overlay_vis_state
      end

      dialog.add_action_callback('deleteMeasurement') do |_ctx, eid_str|
        begin
          eid = eid_str.to_s.to_i
          Highlighter.delete_measurement(eid)
          Dashboard.invalidate_measurement_cache
          Dashboard.send_live_data
          Dashboard.send_measurement_data
          Dashboard.send_overlay_vis_state
        rescue => e
          puts "Takeoff deleteMeasurement error: #{e.message}"
        end
      end

      dialog.add_action_callback('combineMeasurements') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          Highlighter.combine_measurements(data['targetEid'].to_i, data['sourceEid'].to_i)
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
          Dashboard.send_live_data
          MeasurementsPanel.send_data rescue nil
        rescue => e
          puts "Takeoff combineMeasurements error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('requestMeasurements') do |_ctx|
        Dashboard.heartbeat_start('Loading measurements...')
        Dashboard.invalidate_measurement_cache
        Dashboard.send_measurement_data
        Dashboard.heartbeat_stop
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
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "Dashboard createDerivedPart error: #{e.message}"
        end
      end

      dialog.add_action_callback('linkCardAsPart') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          m = Sketchup.active_model
          linked_eid = (data['sourceEid'] || 0).to_i

          # Mark the linked group as a child (hides it from card list)
          grp = TakeoffTool.find_entity(linked_eid)
          if grp && grp.valid?
            m.start_operation('Link Card as Part', true)
            dp_json = m.get_attribute('FormAndField', 'derived_parts')
            parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
            id = "dp_#{Time.now.to_i}_#{rand(1000)}"

            # Read the group's color for the part
            rgba_json = grp.get_attribute('TakeoffMeasurement', 'color_rgba')
            data['linkedColor'] = (JSON.parse(rgba_json) rescue nil) if rgba_json

            data['computedValue'] = 0.0  # Will be recomputed
            parts[id] = data
            m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
            grp.set_attribute('TakeoffMeasurement', 'part_link', id)
            m.commit_operation

            Dashboard.invalidate_measurement_cache
            Dashboard.send_measurement_data
          else
            puts "Dashboard linkCardAsPart: group #{linked_eid} not found"
          end
        rescue => e
          puts "Dashboard linkCardAsPart error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('createPartAndMeasure') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          m = Sketchup.active_model

          # Create derived part record (sourceEid will be set when tool finishes)
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          id = "dp_#{Time.now.to_i}_#{rand(1000)}"
          data['sourceEid'] = 0
          data['computedValue'] = 0.0
          parts[id] = data
          m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))

          # Resolve color from parent measurement group
          src_type = data['sourceType']
          cat = data['category'] || ''
          label = data['name'] || cat
          parent_eid = (data['parentMeasEid'] || 0).to_i
          color = nil
          if parent_eid > 0
            parent_grp = TakeoffTool.find_entity(parent_eid)
            if parent_grp && parent_grp.valid?
              rgba_json = parent_grp.get_attribute('TakeoffMeasurement', 'color_rgba')
              arr = rgba_json ? (JSON.parse(rgba_json) rescue nil) : nil
              color = arr[0..2] if arr && arr.length >= 3
            end
          end

          # Activate the appropriate measurement tool with part_link_id
          if src_type == 'tool_sf'
            m.select_tool(MeasureSFTool.new(cat, label: label, color: color, part_link_id: id))
          elsif src_type == 'tool_lf'
            m.select_tool(MeasureLFTool.new(cat, label: label, color: color, part_link_id: id))
          elsif src_type == 'tool_vol'
            m.select_tool(MeasureVolTool.new(cat, label: label, color: color, part_link_id: id))
          end
        rescue => e
          puts "Dashboard createPartAndMeasure error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('deleteDerivedPart') do |_ctx, id_str|
        begin
          require 'json'
          m = Sketchup.active_model
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          part = parts[id_str.to_s]
          if part
            src_eid = (part['sourceEid'] || 0).to_i
            if part['sourceType'] == 'tool_sf' || part['sourceType'] == 'tool_lf' || part['sourceType'] == 'tool_vol'
              # Tool part: delete the child measurement group
              if src_eid > 0
                grp = TakeoffTool.find_entity(src_eid)
                if grp && grp.valid?
                  m.start_operation('Delete Part Measurement', true)
                  grp.erase!
                  m.commit_operation
                end
              end
            elsif part['sourceType'] == 'linked'
              # Linked part: un-mark the group so it reappears as a standalone card
              if src_eid > 0
                grp = TakeoffTool.find_entity(src_eid)
                if grp && grp.valid?
                  m.start_operation('Unlink Card', true)
                  grp.delete_attribute('TakeoffMeasurement', 'part_link')
                  m.commit_operation
                end
              end
            end
          end
          parts.delete(id_str.to_s)
          m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "Dashboard deleteDerivedPart error: #{e.message}"
        end
      end

      dialog.add_action_callback('deleteDerivedPartPermanent') do |_ctx, id_str|
        begin
          require 'json'
          m = Sketchup.active_model
          dp_json = m.get_attribute('FormAndField', 'derived_parts')
          parts = dp_json && !dp_json.empty? ? JSON.parse(dp_json) : {}
          part = parts[id_str.to_s]
          if part
            src_eid = (part['sourceEid'] || 0).to_i
            if src_eid > 0
              grp = TakeoffTool.find_entity(src_eid)
              if grp && grp.valid?
                m.start_operation('Delete Linked Card', true)
                grp.erase!
                m.commit_operation
              end
            end
          end
          parts.delete(id_str.to_s)
          m.set_attribute('FormAndField', 'derived_parts', JSON.generate(parts))
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "Dashboard deleteDerivedPartPermanent error: #{e.message}"
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
          Dashboard.invalidate_measurement_cache
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
            Dashboard.invalidate_measurement_cache
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

      dialog.add_action_callback('addSFFaces') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          cat = data['category'].to_s
          TakeoffTool.activate_sf_tool_for_group(eid, cat)
        rescue => e
          puts "addSFFaces error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('removeSFFaces') do |_ctx, eid_str|
        begin
          TakeoffTool.activate_remove_sf_tool(eid_str.to_i)
        rescue => e
          puts "removeSFFaces error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('polySFForCat') do |_ctx, cat_str|
        begin
          TakeoffTool.activate_poly_sf_tool(cat_str.to_s)
        rescue => e
          puts "polySFForCat error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('newSFMeasurement') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['category'].to_s
          label = data['label'].to_s
          color = data['color']  # [r,g,b] array
          TakeoffTool.activate_sf_tool_new(cat, label, color)
        rescue => e
          puts "newSFMeasurement error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateSFLabel') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.update_sf_label(data['eid'].to_i, data['label'].to_s)
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "updateSFLabel error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateSFColor') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.update_sf_color(data['eid'].to_i, data['color'])
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "updateSFColor error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      # ─── LF Face Tool callbacks ───

      dialog.add_action_callback('newLFMeasurement') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['category'].to_s
          label = data['label'].to_s
          color = data['color']
          TakeoffTool.activate_lf_face_tool_new(cat, label, color)
        rescue => e
          puts "newLFMeasurement error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('newLFPolyMeasurement') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['category'].to_s
          label = data['label'].to_s
          color = data['color']
          TakeoffTool.activate_lf_tool_new(cat, label, color)
        rescue => e
          puts "newLFPolyMeasurement error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('addLFFaces') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          cat = data['category'].to_s
          TakeoffTool.activate_lf_face_tool_for_group(eid, cat)
        rescue => e
          puts "addLFFaces error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('removeLFFaces') do |_ctx, eid_str|
        begin
          TakeoffTool.activate_remove_sf_tool(eid_str.to_i)
        rescue => e
          puts "removeLFFaces error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateLFLabel') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.update_lf_label(data['eid'].to_i, data['label'].to_s)
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "updateLFLabel error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateLFColor') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.update_lf_color(data['eid'].to_i, data['color'])
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "updateLFColor error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      # ─── Volume Tool callbacks ───

      dialog.add_action_callback('newVolMeasurement') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['category'].to_s
          label = data['label'].to_s
          color = data['color']
          TakeoffTool.activate_vol_tool_new(cat, label, color)
        rescue => e
          puts "newVolMeasurement error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('addVolObjects') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          cat = data['category'].to_s
          TakeoffTool.activate_vol_tool_for_group(eid, cat)
        rescue => e
          puts "addVolObjects error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('removeVolObjects') do |_ctx, eid_str|
        begin
          TakeoffTool.activate_remove_vol_tool(eid_str.to_i)
        rescue => e
          puts "removeVolObjects error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateVolLabel') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.update_vol_label(data['eid'].to_i, data['label'].to_s)
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "updateVolLabel error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateVolColor') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.update_vol_color(data['eid'].to_i, data['color'])
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "updateVolColor error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      # ── Count Measurement ──

      dialog.add_action_callback('measureCount') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['category'].to_s
          label = data['label'] || cat
          color = data['color']
          TakeoffTool.activate_count_tool_new(cat, label, color)
        rescue => e
          puts "measureCount error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('addCountMarkers') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          cat = data['category'].to_s
          TakeoffTool.activate_count_tool_for_group(eid, cat)
        rescue => e
          puts "addCountMarkers error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('removeCountMarkers') do |_ctx, eid_str|
        begin
          TakeoffTool.activate_remove_count_tool(eid_str.to_i)
        rescue => e
          puts "removeCountMarkers error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateCountLabel') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.update_count_label(data['eid'].to_i, data['label'].to_s)
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "updateCountLabel error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateCountColor') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.update_count_color(data['eid'].to_i, data['color'])
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "updateCountColor error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      # ─── WALL callbacks ───

      dialog.add_action_callback('measureWall') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          opts = {
            category: data['category'] || 'Wall Framing',
            label: data['label'] || data['category'] || 'Wall Framing',
            color: data['color'],
            oc_spacing: data['ocSpacing'] || 16,
            plates: data['plates'] || [],
            stud_length: data['studLength'],
            waste: data['waste'] || 5
          }
          TakeoffTool.activate_wall_tool(opts)
        rescue => e
          puts "measureWall error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('addWallSegments') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          cat = data['category'] || 'Wall Framing'
          grp = TakeoffTool.find_entity(eid)
          if grp && grp.valid?
            label = grp.get_attribute('TakeoffMeasurement', 'label') || cat
            # Restore full config from group so plates/OC/waste are preserved
            opts = { category: cat, label: label }
            cfg_json = grp.get_attribute('TakeoffMeasurement', 'wall_config')
            if cfg_json
              cfg = JSON.parse(cfg_json) rescue {}
              opts[:oc_spacing] = cfg['oc_spacing'] if cfg['oc_spacing']
              opts[:plates] = cfg['plates'] if cfg['plates']
              opts[:stud_length] = cfg['stud_length'] if cfg['stud_length']
              opts[:waste] = cfg['waste_pct'] if cfg['waste_pct']
            end
            TakeoffTool.activate_wall_tool(opts)
          end
        rescue => e
          puts "addWallSegments error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('removeWallSegments') do |_ctx, eid_str|
        begin
          TakeoffTool.activate_remove_wall_tool(eid_str.to_i)
        rescue => e
          puts "removeWallSegments error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateWallLabel') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.update_wall_label(data['eid'].to_i, data['label'].to_s)
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "updateWallLabel error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('updateWallColor') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          TakeoffTool.update_wall_color(data['eid'].to_i, data['color'])
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
        rescue => e
          puts "updateWallColor error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      # Forward arrow keys from dashboard to active measurement tool
      dialog.add_action_callback('toolArrowKey') do |_ctx, key_str|
        begin
          key = key_str.to_i
          tool = Sketchup.active_model.tools.active_tool_id rescue nil
          # Send the key event to the active tool if it's a LF Face tool
          active = Sketchup.active_model.tools
          # Use send_action to simulate key — but SketchUp doesn't support this directly.
          # Instead, access the tool instance and call its method.
          t = TakeoffTool.active_lf_face_tool
          if t
            view = Sketchup.active_model.active_view
            t.onKeyDown(key, 1, 0, view)
          end
        rescue => e
          puts "toolArrowKey error: #{e.message}"
        end
      end

      dialog.add_action_callback('reverseSFNormal') do |_ctx, cat_str|
        begin
          cat = cat_str.to_s
          require 'json'
          m = Sketchup.active_model
          next unless m

          # Load current sampled normal (or compute dominant normal)
          existing_json = m.get_attribute('TakeoffSFNormals', cat) rescue nil
          if existing_json
            arr = JSON.parse(existing_json)
            # Flip it
            reversed = [-arr[0], -arr[1], -arr[2]]
          else
            # No sampled normal yet — compute the current dominant from debug data
            # Default: flip the Z axis (up → down or down → up)
            reversed = [0.0, 0.0, -1.0]
            # Check if current dominant is already down-facing
            sr = TakeoffTool.filtered_scan_results || []
            ca = TakeoffTool.category_assignments || {}
            entries = sr.select { |r| (ca[r[:entity_id]] || r[:parsed][:auto_category]) == cat && (r[:area_sf] || 0) > 0 }
            if entries.any?
              e = TakeoffTool.find_entity(entries.first[:entity_id])
              if e && e.valid? && e.respond_to?(:definition)
                top_face = e.definition.entities.grep(Sketchup::Face).first
                if top_face
                  wn = e.transformation * top_face.normal
                  # If dominant is pointing up, reverse to down; and vice versa
                  reversed = wn.z > 0 ? [0.0, 0.0, -1.0] : [0.0, 0.0, 1.0]
                end
              end
            end
          end

          m.set_attribute('TakeoffSFNormals', cat,
            JSON.generate(reversed.map { |v| v.round(6) }))
          puts "[FF ReverseSF] Reversed normal for '#{cat}': [#{reversed.map { |v| v.round(3) }.join(', ')}]"

          # Recalculate SF and repaint
          Scanner.recalculate_sf
          Dashboard.invalidate_measurement_cache rescue nil
          Dashboard.send_measurement_data rescue nil
          Dashboard.send_live_data rescue nil
        rescue => e
          puts "reverseSFNormal error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('adjustEntitySF') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          factor = (data['factor'] || 0.5).to_f
          sr = TakeoffTool.scan_results
          sr.each do |r|
            if r[:entity_id] == eid
              old_sf = r[:area_sf] || 0
              r[:area_sf] = (old_sf * factor).round(2)
              puts "FF: Adjusted SF for eid=#{eid}: #{old_sf.round(2)} → #{r[:area_sf]} (x#{factor})"
              break
            end
          end
          Dashboard.invalidate_measurement_cache rescue nil
          Dashboard.send_live_data rescue nil
        rescue => e
          puts "adjustEntitySF error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      # ─── FF Model Export / Import ───

      dialog.add_action_callback('exportFFModel') do |_ctx, _json|
        begin
          model = Sketchup.active_model
          # Count exportable measurement groups
          export_groups = model.entities.select { |g|
            g.valid? &&
            (g.is_a?(Sketchup::Group) || g.is_a?(Sketchup::ComponentInstance)) &&
            g.get_attribute('TakeoffMeasurement', 'type') &&
            !%w[GRID BENCHMARK].include?(g.get_attribute('TakeoffMeasurement', 'type')) &&
            !g.get_attribute('TakeoffMeasurement', 'part_link')
          }
          if export_groups.empty?
            dialog.execute_script("showToast('No measurements to export','warning')")
            next
          end

          path = UI.savepanel('Export FF Measurements', '', 'measurements.skp')
          next unless path
          path += '.skp' unless path.downcase.end_with?('.skp')

          model.start_operation('Export FF Measurements', true)

          # Mark as FF measurement export
          model.set_attribute('FF_Export', 'type', 'measurements')
          model.set_attribute('FF_Export', 'source_model', File.basename(model.path.to_s))
          model.set_attribute('FF_Export', 'timestamp', Time.now.to_s)
          model.set_attribute('FF_Export', 'count', export_groups.length)

          # Build keep set (entity IDs of measurement groups to export)
          keep_eids = {}
          export_groups.each { |g| keep_eids[g.entityID] = true }

          # Delete everything not in the keep set
          to_delete = model.entities.to_a.reject { |e|
            (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && keep_eids[e.entityID]
          }
          model.entities.erase_entities(to_delete) if to_delete.any?

          # Save only measurements
          status = model.save_copy(path)

          # Abort restores the model to pre-delete state
          model.abort_operation

          if status
            dialog.execute_script("showToast('Exported #{export_groups.length} measurements to #{File.basename(path).gsub("'", "\\\\'")}','success')")
          else
            dialog.execute_script("showToast('Export failed','error')")
          end
        rescue => e
          model.abort_operation rescue nil
          puts "exportFFModel error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
          dialog.execute_script("showToast('Export error: #{e.message.gsub("'", "\\\\'")}','error')") rescue nil
        end
      end

      dialog.add_action_callback('importFFMeasurements') do |_ctx, _json|
        begin
          model = Sketchup.active_model
          path = UI.openpanel('Import FF Measurements', '', 'SketchUp Files|*.skp||')
          next unless path

          model.start_operation('Import FF Measurements', true)

          # Load the .skp as a component definition
          defn = model.definitions.load(path)
          unless defn
            dialog.execute_script("showToast('Failed to load file','error')")
            model.abort_operation
            next
          end

          # Place at origin and explode
          inst = model.entities.add_instance(defn, Geom::Transformation.new)
          exploded = inst.explode || []

          # Ensure TO_Measurements layer exists
          meas_tag = model.layers['TO_Measurements'] || model.layers.add('TO_Measurements')
          source_name = File.basename(path, '.skp')
          imported_count = 0
          to_delete = []

          exploded.each do |e|
            next unless e.valid?
            if (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
               e.get_attribute('TakeoffMeasurement', 'type')
              # Tag as imported
              e.set_attribute('TakeoffMeasurement', 'imported', true)
              e.set_attribute('TakeoffMeasurement', 'import_source', source_name)
              e.layer = meas_tag
              imported_count += 1
            else
              to_delete << e if e.respond_to?(:erase!)
            end
          end

          # Clean up non-measurement leftovers
          to_delete.each { |e| e.erase! if e.valid? } rescue nil

          # Purge the imported definition if unused
          model.definitions.purge_unused

          model.commit_operation

          # Update stored def_count so staleness check doesn't trigger a rescan prompt
          model.set_attribute('FormAndField', 'def_count', TakeoffTool.scannable_def_count(model))

          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data

          if imported_count > 0
            dialog.execute_script("showToast('Imported #{imported_count} measurements from #{source_name.gsub("'", "\\\\'")}','success')")
          else
            dialog.execute_script("showToast('No measurements found in file','warning')")
          end
        rescue => e
          model.abort_operation rescue nil
          puts "importFFMeasurements error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
          dialog.execute_script("showToast('Import error: #{e.message.gsub("'", "\\\\'")}','error')") rescue nil
        end
      end

      dialog.add_action_callback('commitImportedMeasurement') do |_ctx, eid_str|
        begin
          model = Sketchup.active_model
          eid = eid_str.to_s.to_i
          grp = TakeoffTool.find_entity(eid)
          if grp && grp.valid?
            model.start_operation('Commit Imported Measurement', true)
            source = grp.get_attribute('TakeoffMeasurement', 'import_source') || 'Unknown'
            grp.delete_attribute('TakeoffMeasurement', 'imported')
            grp.delete_attribute('TakeoffMeasurement', 'import_source')
            # Stamp commit metadata for commit log + author badge
            grp.set_attribute('TakeoffMeasurement', 'committed_from', source)
            grp.set_attribute('TakeoffMeasurement', 'committed_date', Time.now.strftime('%Y-%m-%d %H:%M'))
            grp.set_attribute('TakeoffMeasurement', 'committed_by', source)
            model.commit_operation
            Dashboard.invalidate_measurement_cache
            Dashboard.send_measurement_data
            Dashboard.send_multiverse_data rescue nil
          end
        rescue => e
          puts "commitImportedMeasurement error: #{e.message}"
        end
      end

      dialog.add_action_callback('discardImportedMeasurement') do |_ctx, eid_str|
        begin
          model = Sketchup.active_model
          eid = eid_str.to_s.to_i
          grp = TakeoffTool.find_entity(eid)
          if grp && grp.valid?
            model.start_operation('Discard Imported Measurement', true)
            grp.erase!
            model.commit_operation
            Dashboard.invalidate_measurement_cache
            Dashboard.send_measurement_data
          end
        rescue => e
          puts "discardImportedMeasurement error: #{e.message}"
        end
      end

      dialog.add_action_callback('commitAllImported') do |_ctx, _json|
        begin
          model = Sketchup.active_model
          model.start_operation('Commit All Imported Measurements', true)
          count = 0
          timestamp = Time.now.strftime('%Y-%m-%d %H:%M')
          model.entities.each do |grp|
            next unless grp.valid?
            next unless grp.is_a?(Sketchup::Group) || grp.is_a?(Sketchup::ComponentInstance)
            next unless grp.get_attribute('TakeoffMeasurement', 'imported')
            source = grp.get_attribute('TakeoffMeasurement', 'import_source') || 'Unknown'
            grp.delete_attribute('TakeoffMeasurement', 'imported')
            grp.delete_attribute('TakeoffMeasurement', 'import_source')
            grp.set_attribute('TakeoffMeasurement', 'committed_from', source)
            grp.set_attribute('TakeoffMeasurement', 'committed_date', timestamp)
            grp.set_attribute('TakeoffMeasurement', 'committed_by', source)
            count += 1
          end
          model.commit_operation
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
          Dashboard.send_multiverse_data rescue nil
          dialog.execute_script("showToast('Committed #{count} measurements','success')") if count > 0
        rescue => e
          puts "commitAllImported error: #{e.message}"
        end
      end

      dialog.add_action_callback('discardAllImported') do |_ctx, _json|
        begin
          model = Sketchup.active_model
          model.start_operation('Discard All Imported Measurements', true)
          to_erase = model.entities.select { |g|
            g.valid? &&
            (g.is_a?(Sketchup::Group) || g.is_a?(Sketchup::ComponentInstance)) &&
            g.get_attribute('TakeoffMeasurement', 'imported')
          }
          count = to_erase.length
          model.entities.erase_entities(to_erase) if to_erase.any?
          model.commit_operation
          Dashboard.invalidate_measurement_cache
          Dashboard.send_measurement_data
          dialog.execute_script("showToast('Discarded #{count} imported measurements','success')") if count > 0
        rescue => e
          puts "discardAllImported error: #{e.message}"
        end
      end

      # ─── Measurement Comparison (VS) ───

      dialog.add_action_callback('startMeasComparison') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          imported_eid = data['eid'].to_i
          mtype = data['type'].to_s    # SF, LF, VOL, COUNT, WALL
          cat = data['category'].to_s

          model = Sketchup.active_model
          imported_grp = TakeoffTool.find_entity(imported_eid)
          next unless imported_grp && imported_grp.valid? && model

          model.start_operation('Start Measurement Comparison', true)

          tag = model.layers['TO_Measurements'] || model.layers.add('TO_Measurements')
          imported_label = imported_grp.get_attribute('TakeoffMeasurement', 'label') || cat
          vs_label = "VS: #{imported_label}"

          # Peach comparison color
          vs_color = [250, 179, 135]

          grp = model.active_entities.add_group
          grp.entities.add_cpoint(ORIGIN)  # keep group alive through commit_operation
          grp.layer = tag
          grp.name = "TO_#{mtype}: #{vs_label}"
          grp.set_attribute('TakeoffMeasurement', 'type', mtype)
          grp.set_attribute('TakeoffMeasurement', 'category', cat)
          grp.set_attribute('TakeoffMeasurement', 'label', vs_label)
          grp.set_attribute('TakeoffMeasurement', 'timestamp', Time.now.to_s)
          grp.set_attribute('TakeoffMeasurement', 'highlights_visible', true)
          grp.set_attribute('TakeoffMeasurement', 'vs_target', imported_eid)

          case mtype
          when 'SF'
            grp.set_attribute('TakeoffMeasurement', 'total_sf', 0.0)
            grp.set_attribute('TakeoffMeasurement', 'face_count', 0)
            grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([*vs_color, 153]))
            grp.set_attribute('TakeoffMeasurement', 'material_name', "FF_VS_#{grp.entityID}")
          when 'LF'
            grp.set_attribute('TakeoffMeasurement', 'total_ft', 0.0)
            grp.set_attribute('TakeoffMeasurement', 'segment_count', 0)
            grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([*vs_color, 179]))
            grp.set_attribute('TakeoffMeasurement', 'material_name', "FF_VS_#{grp.entityID}")
          when 'VOL'
            grp.set_attribute('TakeoffMeasurement', 'total_cy', 0.0)
            grp.set_attribute('TakeoffMeasurement', 'object_count', 0)
            grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([*vs_color, 102]))
            grp.set_attribute('TakeoffMeasurement', 'material_name', "FF_VS_#{grp.entityID}")
          when 'COUNT'
            grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([*vs_color, 179]))
            grp.set_attribute('TakeoffMeasurement', 'material_name', "FF_VS_#{grp.entityID}")
          when 'WALL'
            grp.set_attribute('TakeoffMeasurement', 'total_lf', 0.0)
            grp.set_attribute('TakeoffMeasurement', 'segment_count', 0)
            grp.set_attribute('TakeoffMeasurement', 'total_studs', 0)
            grp.set_attribute('TakeoffMeasurement', 'color_rgba', JSON.generate([*vs_color, 200]))
            grp.set_attribute('TakeoffMeasurement', 'material_name', "FF_VS_#{grp.entityID}")
            # Copy wall config from imported group
            cfg_json = imported_grp.get_attribute('TakeoffMeasurement', 'wall_config')
            grp.set_attribute('TakeoffMeasurement', 'wall_config', cfg_json) if cfg_json
            grp.set_attribute('TakeoffMeasurement', 'oc_spacing',
              imported_grp.get_attribute('TakeoffMeasurement', 'oc_spacing') || 16)
          end

          # Cross-link: imported card knows about the local comparison
          imported_grp.set_attribute('TakeoffMeasurement', 'vs_local', grp.entityID)

          TakeoffTool.entity_registry[grp.entityID] = grp rescue nil
          TakeoffTool.invalidate_entity_cache rescue nil
          model.commit_operation

          # Activate the appropriate measurement tool for the new group
          new_eid = grp.entityID
          case mtype
          when 'SF'
            TakeoffTool.activate_sf_tool_for_group(new_eid, cat)
          when 'LF'
            TakeoffTool.activate_lf_face_tool_for_group(new_eid, cat)
          when 'VOL'
            TakeoffTool.activate_vol_tool_for_group(new_eid, cat)
          when 'COUNT'
            TakeoffTool.activate_count_tool_for_group(new_eid, cat)
          when 'WALL'
            opts = { category: cat, label: vs_label }
            cfg = cfg_json ? (JSON.parse(cfg_json) rescue {}) : {}
            opts[:oc_spacing] = cfg['oc_spacing'] if cfg['oc_spacing']
            opts[:plates] = cfg['plates'] if cfg['plates']
            opts[:waste] = cfg['waste_pct'] if cfg['waste_pct']
            TakeoffTool.activate_wall_tool(opts)
          end

          dialog.execute_script("showToast('Measure to compare \u2014 press Escape when done','info')")
        rescue => e
          Sketchup.active_model.abort_operation rescue nil
          puts "startMeasComparison error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

    end
  end
end
