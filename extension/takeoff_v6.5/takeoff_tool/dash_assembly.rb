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
          puts "Takeoff: createAssembly received #{ids.length} entity IDs from JS (first 5: #{ids.first(5).inspect})"
          next if name.empty? || ids.empty?
          TakeoffTool.create_assembly(name, ids, notes)
          puts "Takeoff: Created assembly '#{name}' with #{ids.length} entities"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff createAssembly error: #{e.message}"
        end
      end

      # Create assembly from all entities currently VISIBLE in the viewport
      # This captures every isolation method (eye toggles, category isolate,
      # filter isolation, search) since they all set entity.visible = false
      dialog.add_action_callback('createAssemblyFromVisible') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s.strip
          notes = data['notes'].to_s
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

          TakeoffTool.create_assembly(name, visible_ids, notes)
          puts "Takeoff: Created assembly '#{name}' with #{visible_ids.length} visible entities (of #{(TakeoffTool.scan_results || []).length} total)"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff createAssemblyFromVisible error: #{e.message}"
        end
      end

      dialog.add_action_callback('deleteAssembly') do |_ctx, name_str|
        begin
          name = name_str.to_s.strip
          TakeoffTool.delete_assembly(name)
          puts "Takeoff: Deleted assembly '#{name}'"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff deleteAssembly error: #{e.message}"
        end
      end

      dialog.add_action_callback('renameAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          old_name = data['oldName'].to_s.strip
          new_name = data['newName'].to_s.strip
          next if old_name.empty? || new_name.empty?
          TakeoffTool.rename_assembly(old_name, new_name)
          puts "Takeoff: Renamed assembly '#{old_name}' -> '#{new_name}'"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff renameAssembly error: #{e.message}"
        end
      end

      dialog.add_action_callback('updateAssembly') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          name = data['name'].to_s.strip
          next if name.empty?
          ids = data['entityIds']
          notes = data.key?('notes') ? data['notes'].to_s : nil
          TakeoffTool.update_assembly(name, entity_ids: ids, notes: notes)
          puts "Takeoff: Updated assembly '#{name}'"
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
          sel = Sketchup.active_model&.selection
          next unless sel && !sel.empty? && !name.empty?
          ids = sel.to_a.select { |e| e.respond_to?(:entityID) }.map(&:entityID)
          next if ids.empty?
          TakeoffTool.create_assembly(name, ids, notes)
          puts "Takeoff: Created assembly '#{name}' from selection (#{ids.length} entities)"
          Dashboard.send_assemblies
        rescue => e
          puts "Takeoff createAssemblyFromSelection error: #{e.message}"
        end
      end

    end
  end
end
