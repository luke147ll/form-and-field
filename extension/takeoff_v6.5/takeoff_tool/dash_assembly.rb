module TakeoffTool
  class DashAssembly
    def self.register_callbacks(dialog)

      dialog.add_action_callback('loadAssemblies') do |_ctx|
        Dashboard.heartbeat_start('Loading assemblies...')
        Dashboard.send_assemblies
        Dashboard.heartbeat_stop
      end

      dialog.add_action_callback('createAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s.strip
          ids = data['entityIds'] || []
          notes = data['notes'].to_s
          zone = data['zone'].to_s
          puts "Takeoff: createAssembly received #{ids.length} entity IDs from JS"
          next if name.empty? || ids.empty?
          asm_id = TakeoffTool.create_assembly(name, ids, notes, zone)
          puts "Takeoff: Created assembly '#{name}' (#{asm_id}) with #{ids.length} entities"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff createAssembly error: #{e.message}"
        end
      end

      # Create assembly from all entities currently VISIBLE in the viewport
      dialog.add_action_callback('createAssemblyFromVisible') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s.strip
          notes = data['notes'].to_s
          zone = data['zone'].to_s
          next if name.empty?

          visible_ids = []
          (TakeoffTool.scan_results || []).each do |r|
            eid = r[:entity_id]
            e = TakeoffTool.find_entity(eid)
            next unless e && e.valid? && e.visible?
            visible_ids << eid
          end

          if visible_ids.empty?
            puts "Takeoff: createAssemblyFromVisible — no visible entities found"
            dialog.execute_script("alert('No visible entities to save.')")
            next
          end

          asm_id = TakeoffTool.create_assembly(name, visible_ids, notes, zone)
          puts "Takeoff: Created assembly '#{name}' (#{asm_id}) with #{visible_ids.length} visible entities"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff createAssemblyFromVisible error: #{e.message}"
        end
      end

      dialog.add_action_callback('deleteAssembly') do |_ctx, asm_id_str|
        begin
          asm_id = asm_id_str.to_s.strip
          TakeoffTool.delete_assembly(asm_id)
          puts "Takeoff: Deleted assembly '#{asm_id}'"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff deleteAssembly error: #{e.message}"
        end
      end

      dialog.add_action_callback('renameAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          new_name = data['newName'].to_s.strip
          next if asm_id.empty? || new_name.empty?
          TakeoffTool.rename_assembly(asm_id, new_name)
          puts "Takeoff: Renamed assembly #{asm_id} -> '#{new_name}'"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff renameAssembly error: #{e.message}"
        end
      end

      dialog.add_action_callback('updateAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          next if asm_id.empty?
          notes = data.key?('notes') ? data['notes'].to_s : nil
          zone = data.key?('zone') ? data['zone'].to_s : nil
          TakeoffTool.update_assembly(asm_id, notes: notes, zone: zone)
          puts "Takeoff: Updated assembly #{asm_id}"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff updateAssembly error: #{e.message}"
        end
      end

      dialog.add_action_callback('createAssemblyFromSelection') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s.strip
          notes = data['notes'].to_s
          zone = data['zone'].to_s
          sel = Sketchup.active_model&.selection
          next unless sel && !sel.empty? && !name.empty?
          ids = sel.to_a.select { |e| e.respond_to?(:entityID) }.map(&:entityID)
          next if ids.empty?
          asm_id = TakeoffTool.create_assembly(name, ids, notes, zone)
          puts "Takeoff: Created assembly '#{name}' (#{asm_id}) from selection (#{ids.length} entities)"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff createAssemblyFromSelection error: #{e.message}"
        end
      end

      # ─── NEW: Part CRUD callbacks ───

      dialog.add_action_callback('setAsmRoomZone') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          zone = data['zone'].to_s
          next if asm_id.empty?
          TakeoffTool.update_assembly(asm_id, zone: zone)
          puts "Takeoff: Set zone for #{asm_id} -> '#{zone}'"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff setAsmRoomZone error: #{e.message}"
        end
      end

      dialog.add_action_callback('addToAssemblyFromSelection') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          next if asm_id.empty?
          count = TakeoffTool.add_parts_from_selection(asm_id)
          puts "Takeoff: Added #{count} parts from selection to #{asm_id}"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff addToAssemblyFromSelection error: #{e.message}"
        end
      end

      dialog.add_action_callback('addVirtualPart') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          name = data['name'].to_s.strip
          next if asm_id.empty? || name.empty?
          pn = TakeoffTool.add_virtual_part(
            asm_id,
            name: name,
            category: data['category'].to_s,
            quantity: data['qty'].to_i,
            unit: data['unit'].to_s,
            notes: data['notes'].to_s
          )
          puts "Takeoff: Added virtual part #{pn} to #{asm_id}"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff addVirtualPart error: #{e.message}"
        end
      end

      dialog.add_action_callback('deleteAsmPart') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          part_number = data['partNumber'].to_s.strip
          next if asm_id.empty? || part_number.empty?
          TakeoffTool.remove_part(asm_id, part_number)
          puts "Takeoff: Deleted part #{part_number} from #{asm_id}"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff deleteAsmPart error: #{e.message}"
        end
      end

      dialog.add_action_callback('removePartsFromAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          eids = (data['eids'] || []).map(&:to_i)
          next if asm_id.empty? || eids.empty?
          count = TakeoffTool.remove_parts_by_eids(asm_id, eids)
          puts "Takeoff: Removed #{count} parts from #{asm_id}"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff removePartsFromAssembly error: #{e.message}"
        end
      end

      dialog.add_action_callback('updateAsmPart') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          part_number = data['partNumber'].to_s.strip
          fields = data['fields'] || {}
          next if asm_id.empty? || part_number.empty?
          TakeoffTool.update_part(asm_id, part_number, fields)
          puts "Takeoff: Updated part #{part_number} in #{asm_id}"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff updateAsmPart error: #{e.message}"
        end
      end

      dialog.add_action_callback('isolateAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          next if asm_id.empty?
          assemblies = TakeoffTool.load_assemblies
          asm = assemblies[asm_id]
          next unless asm
          parts = asm['parts'] || []
          eids = parts.reject { |p| p['is_virtual'] }.map { |p| p['entity_id'] }.compact.map(&:to_i)
          if eids.empty?
            puts "Takeoff: isolateAssembly — no modeled entities in #{asm_id}"
            next
          end
          VisibilityManager.isolate(eids, source: "assembly:#{asm['name']}")
          puts "Takeoff: Isolated #{eids.length} entities for assembly #{asm_id}"
          Dashboard.send_live_data
        rescue => e
          puts "Takeoff isolateAssembly error: #{e.message}"
        end
      end

      dialog.add_action_callback('toggleAsmTags') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          visible = data['visible']
          next if asm_id.empty?
          if visible
            AssemblyAnnotations.show_tags(asm_id)
          else
            AssemblyAnnotations.hide_tags(asm_id)
          end
          TakeoffTool.asm_tags_visible[asm_id] = visible
          puts "Takeoff: Tags #{visible ? 'shown' : 'hidden'} for #{asm_id}"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff toggleAsmTags error: #{e.message}"
        end
      end

      dialog.add_action_callback('autoTagAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          prefix = data['prefix'].to_s
          color  = data['color'].to_s
          next if asm_id.empty?
          tag_list = AssemblyAnnotations.place_auto_tags(asm_id, prefix, color) || []
          if tag_list.any?
            safe = JSON.generate({ 'asmId' => asm_id, 'tags' => tag_list }).gsub('</') { '<\\/' }
            dialog.execute_script("receiveAutoTags(#{safe})") rescue nil
          end
        rescue => e
          puts "Takeoff autoTagAssembly error: #{e.message}"
        end
      end

      dialog.add_action_callback('clearAutoTags') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          next if asm_id.empty?
          AssemblyAnnotations.cleanup_auto_tags(asm_id)
          puts "Takeoff: Cleared auto tags for #{asm_id}"
        rescue => e
          puts "Takeoff clearAutoTags error: #{e.message}"
        end
      end

      dialog.add_action_callback('exportAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          asm_id = data['asmId'].to_s.strip
          next if asm_id.empty?
          Exporter.export_assembly(asm_id)
          puts "Takeoff: Exported assembly #{asm_id}"
        rescue => e
          puts "Takeoff exportAssembly error: #{e.message}"
        end
      end

      # ─── Parts List callbacks ───

      dialog.add_action_callback('getPartsList') do |_ctx, name_str|
        begin
          require 'json'
          Dashboard.heartbeat_start('Building parts list...')
          data = TakeoffTool.generate_parts_list(name_str.to_s)
          Dashboard.heartbeat_stop
          if data
            safe = JSON.generate(data).gsub('</') { '<\\/' }
            dialog.execute_script("receivePartsList(#{safe})") rescue nil
          end
        rescue => e
          Dashboard.heartbeat_stop rescue nil
          puts "Takeoff getPartsList error: #{e.message}"
        end
      end

      dialog.add_action_callback('setEntitySku') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          sku = data['sku'].to_s.strip
          TakeoffTool.set_entity_sku(eid, sku)
        rescue => e
          puts "Takeoff setEntitySku error: #{e.message}"
        end
      end

      dialog.add_action_callback('setDefinitionSku') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          eid = data['eid'].to_i
          sku = data['sku'].to_s.strip
          count = TakeoffTool.set_definition_sku(eid, sku)
          dialog.execute_script("alert('SKU applied to #{count} instances')") rescue nil
        rescue => e
          puts "Takeoff setDefinitionSku error: #{e.message}"
        end
      end

      dialog.add_action_callback('exportPartsList') do |_ctx, name_str|
        begin
          TakeoffTool.export_parts_list_csv(name_str.to_s)
        rescue => e
          puts "Takeoff exportPartsList error: #{e.message}"
        end
      end

      dialog.add_action_callback('importCadworksCSV') do |_ctx|
        begin
          path = UI.openpanel('Import Cadworks CSV', '', 'CSV Files|*.csv||')
          if path
            Dashboard.heartbeat_start('Importing Cadworks CSV...')
            result = TakeoffTool.import_cadworks_csv(path)
            Dashboard.heartbeat_stop
            Dashboard.send_assemblies
            Dashboard.send_live_data
            dialog.execute_script("alert('Matched #{result[:matched]} of #{result[:total]} rows. SKUs and zones applied.')") rescue nil
          end
        rescue => e
          Dashboard.heartbeat_stop rescue nil
          puts "Takeoff importCadworksCSV error: #{e.message}"
        end
      end

      dialog.add_action_callback('clearAutoAssemblies') do |_ctx|
        begin
          count = TakeoffTool.clear_auto_assemblies
          Dashboard.send_assemblies
          dialog.execute_script("alert('Cleared #{count} auto-created assemblies')") rescue nil
        rescue => e
          puts "Takeoff clearAutoAssemblies error: #{e.message}"
        end
      end

    end
  end
end
