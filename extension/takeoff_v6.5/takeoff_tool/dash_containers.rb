module TakeoffTool
  class DashContainers
    def self.register_callbacks(dialog)

      dialog.add_action_callback('addContainer') do |_ctx, name_str|
        begin
          name = name_str.to_s.strip
          unless name.empty?
            TakeoffTool.add_container(name)
            puts "[FF] addContainer '#{name}' — now #{(TakeoffTool.master_containers || []).length} containers"
            Dashboard.send_live_data
          end
        rescue => e
          puts "[FF] addContainer ERROR: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('deleteContainer') do |_ctx, name_str|
        begin
          name = name_str.to_s.strip
          unless name.empty?
            TakeoffTool.delete_container(name)
            puts "[FF] deleteContainer '#{name}' — now #{(TakeoffTool.master_containers || []).length} containers"
            Dashboard.send_live_data
          end
        rescue => e
          puts "[FF] deleteContainer ERROR: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end

      dialog.add_action_callback('addCategoryToContainer') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat_name = data['category'].to_s.strip
          cont_name = data['container'].to_s.strip
          unless cat_name.empty? || cont_name.empty?
            TakeoffTool.add_category_to_container(cat_name, cont_name)
            Dashboard.send_live_data
            puts "Takeoff: addCategoryToContainer '#{cat_name}' in '#{cont_name}'"
          end
        rescue => e
          puts "Takeoff addCategoryToContainer error: #{e.message}"
        end
      end

      dialog.add_action_callback('moveCategoryToContainer') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat_name = data['category'].to_s.strip
          target_cont = data['targetContainer'].to_s.strip
          TakeoffTool.move_category_to_container(cat_name, target_cont)
        rescue => e
          puts "Takeoff moveCategoryToContainer error: #{e.message}"
        end
      end

      dialog.add_action_callback('addSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          name = data['name'].to_s.strip
          TakeoffTool.add_subcategory(cat, name)
        rescue => e
          puts "Takeoff addSubcategory error: #{e.message}"
        end
      end

      dialog.add_action_callback('renameSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          old_name = data['oldName'].to_s.strip
          new_name = data['newName'].to_s.strip
          TakeoffTool.rename_subcategory(cat, old_name, new_name)
        rescue => e
          puts "Takeoff renameSubcategory error: #{e.message}"
        end
      end

      dialog.add_action_callback('deleteSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['cat'].to_s.strip
          name = data['name'].to_s.strip
          TakeoffTool.remove_subcategory(cat, name)
        rescue => e
          puts "Takeoff deleteSubcategory error: #{e.message}"
        end
      end

      dialog.add_action_callback('moveSubcategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          source_cat = data['sourceCat'].to_s.strip
          sub_name = data['sub'].to_s.strip
          target_cat = data['targetCat'].to_s.strip
          TakeoffTool.move_subcategory(source_cat, sub_name, target_cat)
        rescue => e
          puts "Takeoff moveSubcategory error: #{e.message}"
        end
      end

    end
  end
end
