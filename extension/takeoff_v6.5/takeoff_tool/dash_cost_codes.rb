module TakeoffTool
  module DashCostCodes

    @dialog = nil

    def self.show
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Form and Field \u2014 Cost Code Editor",
        preferences_key: "FF_CostCodeEditor",
        width: 960, height: 680,
        left: 120, top: 100,
        resizable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(File.join(PLUGIN_DIR, 'ui', 'cost_code_editor.html'))
      register_callbacks
      @dialog.show
    end

    def self.dialog
      @dialog
    end

    # ── Push data to JS ──

    def self.push_data
      return unless @dialog && @dialog.visible?
      require 'json'
      cc_data = TakeoffTool.effective_cost_codes
      cats = TakeoffTool.master_categories || []
      payload = {
        codes: cc_data['codes'] || [],
        categoryMap: cc_data['category_to_cost_code'] || {},
        categories: cats.reject { |c| c == '_IGNORE' }
      }
      safe = JSON.generate(payload).gsub('</') { '<\\/' }
      @dialog.execute_script("receiveCCData(#{safe})")
    rescue => e
      puts "[FF CostCodeEditor] push_data error: #{e.message}"
    end

    private

    def self.register_callbacks
      @dialog.add_action_callback('ccRequestData') do |_ctx|
        push_data
      end

      @dialog.add_action_callback('ccAddCode') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          code = data['code'].to_s.strip
          desc = data['description'].to_s.strip
          if code.empty?
            @dialog.execute_script("showToast('Code cannot be empty','error')") rescue nil
            next
          end
          ok = TakeoffTool.add_cost_code(code, desc)
          if ok
            push_data
            @dialog.execute_script("showToast('Added #{code}','success')") rescue nil
          else
            @dialog.execute_script("showToast('Code #{code} already exists','error')") rescue nil
          end
        rescue => e
          puts "[FF CostCodeEditor] ccAddCode error: #{e.message}"
        end
      end

      @dialog.add_action_callback('ccEditCode') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          old_code = data['oldCode'].to_s.strip
          new_code = data['newCode'].to_s.strip
          desc = data['description'].to_s.strip
          next if old_code.empty? || new_code.empty?

          cc = TakeoffTool.load_user_cost_codes || TakeoffTool.effective_cost_codes.dup
          cc['codes'] ||= []
          # Update code entry
          cc['codes'].each do |c|
            if c['code'] == old_code
              c['code'] = new_code
              c['description'] = desc
              c['full'] = "#{new_code} #{desc}"
              break
            end
          end
          cc['codes'].sort_by! { |c| c['code'] }
          # Remap category assignments
          ccm = cc['category_to_cost_code'] || {}
          ccm.each do |_cat, codes|
            next unless codes.is_a?(Array)
            codes.map! { |c| c == old_code ? new_code : c }
          end
          # Remap entity-level assignments
          (TakeoffTool.cost_code_assignments || {}).each do |eid, val|
            TakeoffTool.cost_code_assignments[eid] = new_code if val == old_code
          end
          TakeoffTool.save_user_cost_codes(cc)
          TakeoffTool.publish(EVENT_CATEGORIES_CHANGED)
          push_data
          @dialog.execute_script("showToast('Updated #{new_code}','success')") rescue nil
        rescue => e
          puts "[FF CostCodeEditor] ccEditCode error: #{e.message}"
        end
      end

      @dialog.add_action_callback('ccRemoveCode') do |_ctx, code_str|
        begin
          code = code_str.to_s.strip
          TakeoffTool.remove_cost_code(code)
          push_data
          @dialog.execute_script("showToast('Removed #{code}','warning')") rescue nil
        rescue => e
          puts "[FF CostCodeEditor] ccRemoveCode error: #{e.message}"
        end
      end

      @dialog.add_action_callback('ccSetCategoryCode') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['category'].to_s
          code = data['code'].to_s.strip
          next if cat.empty? || code.empty?

          cc = TakeoffTool.load_user_cost_codes || TakeoffTool.effective_cost_codes.dup
          cc['category_to_cost_code'] ||= {}
          existing = cc['category_to_cost_code'][cat] || []
          unless existing.include?(code)
            existing << code
            cc['category_to_cost_code'][cat] = existing
          end
          TakeoffTool.save_user_cost_codes(cc)
          TakeoffTool.publish(EVENT_CATEGORIES_CHANGED)
          push_data
        rescue => e
          puts "[FF CostCodeEditor] ccSetCategoryCode error: #{e.message}"
        end
      end

      @dialog.add_action_callback('ccRemoveCategoryCode') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cat = data['category'].to_s
          code = data['code'].to_s.strip
          next if cat.empty?

          cc = TakeoffTool.load_user_cost_codes || TakeoffTool.effective_cost_codes.dup
          cc['category_to_cost_code'] ||= {}
          arr = cc['category_to_cost_code'][cat]
          if arr.is_a?(Array)
            arr.delete(code)
            cc['category_to_cost_code'].delete(cat) if arr.empty?
          end
          TakeoffTool.save_user_cost_codes(cc)
          TakeoffTool.publish(EVENT_CATEGORIES_CHANGED)
          push_data
        rescue => e
          puts "[FF CostCodeEditor] ccRemoveCategoryCode error: #{e.message}"
        end
      end

      @dialog.add_action_callback('ccImportCSV') do |_ctx|
        begin
          path = UI.openpanel('Import Cost Codes CSV', '', 'CSV Files|*.csv||')
          if path
            count = TakeoffTool.import_cost_codes_from_csv(path)
            push_data
            @dialog.execute_script("showToast('Imported #{count.to_i} cost codes','success')") rescue nil
          end
        rescue => e
          puts "[FF CostCodeEditor] ccImportCSV error: #{e.message}"
        end
      end

      @dialog.add_action_callback('ccExportCSV') do |_ctx|
        begin
          path = UI.savepanel('Export Cost Codes CSV', '', 'cost_codes.csv')
          if path
            path += '.csv' unless path.end_with?('.csv')
            cc = TakeoffTool.effective_cost_codes
            codes = cc['codes'] || []
            File.open(path, 'w') do |f|
              f.puts "code,description"
              codes.each { |c| f.puts "#{c['code']},\"#{c['description']}\"" }
            end
            @dialog.execute_script("showToast('Exported #{codes.length} codes','success')") rescue nil
          end
        rescue => e
          puts "[FF CostCodeEditor] ccExportCSV error: #{e.message}"
        end
      end

      @dialog.add_action_callback('ccResetDefaults') do |_ctx|
        begin
          m = Sketchup.active_model
          m.delete_attribute('FormAndField', 'user_cost_codes') if m
          TakeoffTool.publish(EVENT_CATEGORIES_CHANGED)
          push_data
          @dialog.execute_script("showToast('Reset to default cost codes','success')") rescue nil
        rescue => e
          puts "[FF CostCodeEditor] ccResetDefaults error: #{e.message}"
        end
      end
    end

  end
end
