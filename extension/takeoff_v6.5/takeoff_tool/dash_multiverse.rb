module TakeoffTool
  class DashMultiverse
    def self.register_callbacks(dialog)

      # ═══ MULTIVERSE ═══

      dialog.add_action_callback('setMultiverseView') do |_ctx, mode_str|
        TakeoffTool.set_multiverse_view(mode_str.to_s)
      end

      dialog.add_action_callback('importComparisonModel') do |_ctx|
        TakeoffTool.import_comparison_model
      end

      dialog.add_action_callback('removeComparisonModel') do |_ctx|
        TakeoffTool.remove_comparison_model
      end

      dialog.add_action_callback('requestMultiverseData') do |_ctx|
        Dashboard.heartbeat_start('Loading multiverse...')
        Dashboard.send_multiverse_data
        Dashboard.heartbeat_stop
      end

      dialog.add_action_callback('rescanModelB') do |_ctx|
        TakeoffTool.rescan_model_b
      end

      dialog.add_action_callback('rescanModelBWithTemplate') do |_ctx, tpl_name|
        tpl = tpl_name.to_s.strip
        TakeoffTool.rescan_model_b(template_name: tpl.empty? ? nil : tpl)
      end

      dialog.add_action_callback('setModelBTemplate') do |_ctx, tpl_name|
        tpl = tpl_name.to_s.strip
        mv = TakeoffTool.multiverse_data
        if mv
          mv['template_model_b'] = tpl.empty? ? nil : tpl
          TakeoffTool.save_multiverse_data
        end
      end

      dialog.add_action_callback('getTemplateList') do |_ctx|
        require 'json'
        templates = defined?(CategoryTemplates) ? CategoryTemplates.list : []
        mv = TakeoffTool.multiverse_data || {}
        current = mv['template_model_b'] || ''
        payload = { templates: templates, current: current }
        safe = JSON.generate(payload).gsub('</') { '<\\/' }
        dialog.execute_script("receiveTemplateList(#{safe})")
      end

      # ═══ MODEL COMPARISON (Quantity Delta + Visual Diff) ═══

      dialog.add_action_callback('runCompare') do |_ctx|
        begin
          if SmartDiff.active?
            puts "Dashboard: runCompare blocked — SmartDiff is active"
            next
          end
          # Part 1: synchronous quantity delta
          TakeoffTool.compute_quantity_delta
          Dashboard.send_comparison_results
          # Part 2: async visual diff (batched via UI.start_timer)
          TakeoffTool.compute_visual_diff
        rescue => e
          puts "Dashboard: runCompare error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          require 'json'
          err = { 'error' => e.message }
          ejs = JSON.generate(err).gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
          dialog.execute_script("receiveComparisonResults('#{ejs}')")
        end
      end

      dialog.add_action_callback('toggleDiff') do |_ctx|
        begin
          next if SmartDiff.active?
          is_on = TakeoffTool.toggle_diff
          dialog.execute_script("setDiffToggle(#{is_on})")
        rescue => e
          puts "Dashboard: toggleDiff error: #{e.message}"
        end
      end

      dialog.add_action_callback('showChangeReport') do |_ctx|
        begin
          TakeoffTool.show_change_report
        rescue => e
          puts "Dashboard: showChangeReport error: #{e.message}"
        end
      end

      dialog.add_action_callback('clearCompareHighlights') do |_ctx|
        begin
          TakeoffTool.clear_compare_highlights
        rescue => e
          puts "Dashboard: clearCompare error: #{e.message}"
        end
        dialog.execute_script("clearCompareUI()")
      end

      # ═══ SMART DIFF ═══

      dialog.add_action_callback('computeSmartDiff') do |_ctx|
        begin
          SmartDiff.enter
          counts = SmartDiff.counts || {}
          require 'json'
          dialog.execute_script("onSmartDiffComplete(#{JSON.generate(counts)})")
        rescue => e
          msg = "SmartDiff error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          puts msg
          esc = e.message.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", ' ')
          dialog.execute_script("hideLoading();alert('Smart Diff Error: #{esc}')")
        end
      end

      dialog.add_action_callback('setSmartDiffOpacity') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          state = data['state'].to_s
          value = data['value'].to_f
          SmartDiff.set_opacity(state, value)
        rescue => e
          puts "setSmartDiffOpacity error: #{e.message}"
        end
      end

      dialog.add_action_callback('setSmartDiffVisibility') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          state = data['state'].to_s
          visible = data['visible'] == true
          cats = data['categories']  # nil = all, array = filter
          SmartDiff.set_visibility(state, visible)
          SmartDiff.toggle_state_fast(state, visible, category_filter: cats)
        rescue => e
          puts "setSmartDiffVisibility error: #{e.message}"
        end
      end

      # ═══ SMART DIFF — CATEGORY FILTER ═══

      dialog.add_action_callback('smartDiffFilterCategory') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cats = data['categories']  # nil = all, array = filter
          SmartDiff.repaint(category_filter: cats)
        rescue => e
          puts "smartDiffFilterCategory error: #{e.message}"
        end
      end

      dialog.add_action_callback('smartDiffIsolateWithCat') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          state_str = data['state'].to_s
          cats = data['categories']  # nil = all, array = filter
          SmartDiff.isolate_state(state_str, categories: cats)
          dialog.execute_script("onSmartDiffVisUpdate(#{JSON.generate(SmartDiff.visibility_settings)})")
        rescue => e
          puts "smartDiffIsolateWithCat error: #{e.message}"
        end
      end

      dialog.add_action_callback('smartDiffShowAllWithCat') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          cats = data['categories']  # nil = all, array = filter
          SmartDiff.show_all(categories: cats)
          dialog.execute_script("onSmartDiffVisUpdate(#{JSON.generate(SmartDiff.visibility_settings)})")
        rescue => e
          puts "smartDiffShowAllWithCat error: #{e.message}"
        end
      end

      dialog.add_action_callback('removeSmartDiff') do |_ctx|
        begin
          SmartDiff.exit
          dialog.execute_script("onSmartDiffRemoved()")
        rescue => e
          puts "removeSmartDiff error: #{e.message}"
        end
      end

      dialog.add_action_callback('acceptCompare') do |_ctx|
        begin
          result = TakeoffTool.accept_compare
          require 'json'
          js = JSON.generate(result)
          esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
          dialog.execute_script("receiveAcceptResult('#{esc}')")
          # Switch JS UI to Model A view (accept_compare already set Ruby state)
          dialog.execute_script("setMvViewUI('a')")
          # Refresh dashboard with Model A filtered data
          Dashboard.send_live_data
        rescue => e
          puts "Dashboard: acceptCompare error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          err = { 'error' => e.message }
          ejs = JSON.generate(err).gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
          dialog.execute_script("receiveAcceptResult('#{ejs}')")
        end
      end

      # ═══ COMMIT TO MAIN ═══

      dialog.add_action_callback('commitToMain') do |_ctx, cat_str|
        begin
          category = cat_str.to_s.strip
          next if category.empty?
          result = TakeoffTool.commit_to_main(category)
          require 'json'
          js = JSON.generate(result)
          esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
          dialog.execute_script("receiveCommitResult('#{esc}')")
          dialog.execute_script("setMvViewUI('a')")
          Dashboard.send_live_data
        rescue => e
          puts "Dashboard: commitToMain error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          err = { 'error' => e.message }
          ejs = JSON.generate(err).gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
          dialog.execute_script("receiveCommitResult('#{ejs}')")
        end
      end

      dialog.add_action_callback('commitCompareEntities') do |_ctx|
        begin
          result = TakeoffTool.commit_compare_entities
          require 'json'
          js = JSON.generate(result)
          esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
          dialog.execute_script("receiveCommitResult('#{esc}')")
          dialog.execute_script("setMvViewUI('a')")
          Dashboard.send_live_data
        rescue => e
          puts "Dashboard: commitCompareEntities error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          err = { 'error' => e.message }
          ejs = JSON.generate(err).gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
          dialog.execute_script("receiveCommitResult('#{ejs}')")
        end
      end

      dialog.add_action_callback('recallFromVault') do |_ctx|
        result = TakeoffTool.recall_from_vault
        require 'json'
        js = JSON.generate(result)
        esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
        dialog.execute_script("receiveRecallResult('#{esc}')")
      end

      dialog.add_action_callback('requestVaultSummary') do |_ctx|
        require 'json'
        data = TakeoffTool.vault_summary
        js = JSON.generate(data)
        esc = js.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", "\\\\n")
        dialog.execute_script("receiveVaultSummary('#{esc}')")
      end

      # NE review: approve entities — commits scanner category as a firm assignment
      dialog.add_action_callback('neApprove') do |_ctx, json_str|
        begin
          require 'json'
          eids = JSON.parse(json_str.to_s).map(&:to_i)
          ca = TakeoffTool.category_assignments
          sr = TakeoffTool.scan_results
          count = 0
          eids.each do |eid|
            # Get the entity's current effective category
            cat = ca[eid]
            if cat.nil? || cat.empty? || cat == 'Uncategorized'
              r = sr.find { |r| r[:entity_id] == eid }
              cat = r[:parsed][:auto_category] if r
            end
            next unless cat && !cat.empty? && cat != 'Uncategorized'
            ca[eid] = cat
            TakeoffTool.save_assignment(eid, 'category', cat)
            count += 1
          end
          puts "Takeoff: neApprove committed #{count} entities"
          Dashboard.send_live_data if count > 0
        rescue => e
          puts "Takeoff: neApprove error: #{e.message}"
        end
      end

    end
  end
end
