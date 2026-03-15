module TakeoffTool
  class DashScanner
    def self.register_callbacks(dialog)

      dialog.add_action_callback('enterScannerMode') do |_ctx|
        groups = InteractiveScanner.current_groups
        if groups && groups.length > 0
          all_eids = groups.flat_map { |g| g[:entity_ids] }
          Highlighter.isolate_entities(TakeoffTool.filtered_scan_results, all_eids)
          Dashboard.send_scanner_groups
        end
      end

      dialog.add_action_callback('exitScannerMode') do |_ctx|
        Highlighter.show_all
        Highlighter.clear_all
        Dashboard.send_live_data
      end

      dialog.add_action_callback('regroupScanner') do |_ctx, mode_str|
        InteractiveScanner.regroup(mode_str.to_s)
        Dashboard.send_scanner_groups
      end

      dialog.add_action_callback('applyScannerGroup') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          idx = data['groupIdx'].to_i
          category = data['category'].to_s.strip
          subcategory = (data['subcategory'] || '').to_s.strip
          cost_code = (data['costCode'] || '').to_s.strip
          groups = InteractiveScanner.current_groups
          next if category.empty? || idx < 0 || idx >= groups.length

          group = groups[idx]
          InteractiveScanner.apply_to_group(group, category, subcategory, cost_code,
            InteractiveScanner.current_sr, InteractiveScanner.current_ca)
          group[:applied] = true
          (group[:sub_groups] || []).each { |sg| sg[:applied] = true }

          LearningSystem.capture(
            group[:entity_ids].first, 'Uncategorized', category,
            new_subcategory: subcategory.empty? ? nil : subcategory,
            new_cost_code: cost_code.empty? ? nil : cost_code
          )

          Dashboard.send_scanner_groups
          TakeoffTool.trigger_backup
        rescue => e
          puts "Scanner applyScannerGroup error: #{e.message}"
        end
      end

      dialog.add_action_callback('skipScannerGroup') do |_ctx, idx_str|
        idx = idx_str.to_s.to_i
        groups = InteractiveScanner.current_groups
        if idx >= 0 && idx < groups.length
          groups[idx][:applied] = true
          groups[idx][:skipped] = true
          Dashboard.send_scanner_groups
        end
      end

      dialog.add_action_callback('createScannerCategory') do |_ctx, name_str|
        name = name_str.to_s.strip
        unless name.empty?
          TakeoffTool.add_custom_category(name)
          Dashboard.send_scanner_groups
        end
      end

    end
  end
end
